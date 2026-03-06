#!/bin/bash

#############################################
# Cipi Installer
# Version: see version.md
# Author: Andrea Pollastri
# License: MIT
#############################################

set -e

REPO="andreapollastri/cipi"
BRANCH="${1:-latest}"
BUILD=""  # resolved from version.md after git clone in install_cipi()

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

export DEBIAN_FRONTEND=noninteractive

show_logo() {
    clear
    echo -e "${GREEN}${BOLD}"
    echo " ██████ ██ ██████  ██"
    echo "██      ██ ██   ██ ██"
    echo "██      ██ ██████  ██"
    echo "██      ██ ██      ██"
    echo " ██████ ██ ██      ██"
    echo ""
    echo " v${BUILD} — Installation"
    echo -e "${NC}"
    sleep 2
}

step_msg() {
    clear
    echo -e "\n${GREEN}${BOLD}$1${NC}\n"
    sleep 1
}

# ── CHECKS ────────────────────────────────────────────────────

check_requirements() {
    step_msg "Checking requirements..."

    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}Error: run as root (sudo)${NC}"
        exit 1
    fi

    if [ ! -f /etc/os-release ]; then
        echo -e "${RED}Error: cannot detect OS${NC}"
        exit 1
    fi

    . /etc/os-release

    if [ "$ID" != "ubuntu" ]; then
        echo -e "${RED}Error: Cipi requires Ubuntu (found: $ID)${NC}"
        exit 1
    fi

    version_check=$(echo "$VERSION_ID >= 24.04" | bc 2>/dev/null || echo 0)
    if [ "$version_check" -ne 1 ]; then
        echo -e "${RED}Error: requires Ubuntu 24.04+ (found: $VERSION_ID)${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Ubuntu $VERSION_ID — root${NC}"
}

# ── BASE PACKAGES ─────────────────────────────────────────────

install_basics() {
    step_msg "Installing base packages..."

    apt-get update -qq
    apt-get install -y -qq \
        software-properties-common curl wget nano vim git \
        zip unzip openssl expect apt-transport-https \
        ca-certificates gnupg lsb-release jq bc acl \
        logrotate cron htop ncdu \
        unattended-upgrades apt-listchanges

    echo -e "${GREEN}✓ Base packages${NC}"
}

# ── SWAP ──────────────────────────────────────────────────────

setup_swap() {
    step_msg "Configuring swap..."

    if [ -f /var/swap.1 ]; then
        echo -e "${GREEN}✓ Swap already configured${NC}"
        return
    fi

    local ram_mb
    ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    local swap_mb=$((ram_mb * 2))
    [ "$swap_mb" -gt 4096 ] && swap_mb=4096
    [ "$swap_mb" -lt 1024 ] && swap_mb=1024

    dd if=/dev/zero of=/var/swap.1 bs=1M count=$swap_mb status=none
    chmod 600 /var/swap.1
    mkswap /var/swap.1 &>/dev/null
    swapon /var/swap.1
    echo '/var/swap.1 none swap sw 0 0' >> /etc/fstab

    echo 'vm.swappiness=10' >> /etc/sysctl.conf
    sysctl vm.swappiness=10 &>/dev/null

    echo -e "${GREEN}✓ Swap ${swap_mb}MB${NC}"
}

# ── SYSTEM ────────────────────────────────────────────────────

setup_system() {
    step_msg "Configuring system..."

    # Default editor
    cat > /etc/profile.d/cipi-env.sh <<'EOF'
export EDITOR=nano
export VISUAL=nano
EOF
    chmod +x /etc/profile.d/cipi-env.sh

    # MOTD
    cat > /etc/motd <<'EOF'

 ██████ ██ ██████  ██
██      ██ ██   ██ ██
██      ██ ██████  ██
██      ██ ██      ██
 ██████ ██ ██      ██

Easy Laravel Deployments

EOF

    echo -e "${GREEN}✓ System configured${NC}"
}

# ── NGINX ─────────────────────────────────────────────────────

install_nginx() {
    step_msg "Installing Nginx..."

    apt-get install -y -qq nginx libnginx-mod-http-headers-more-filter

    local CPU_CORES
    CPU_CORES=$(nproc)

    cat > /etc/nginx/nginx.conf <<NGINXEOF
user www-data;
worker_processes ${CPU_CORES};
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 2048;
    multi_accept on;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_names_hash_bucket_size 64;
    server_tokens off;
    more_clear_headers 'Server' 'X-Powered-By';

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript
               application/json application/javascript application/xml+rss
               application/rss+xml font/truetype font/opentype
               application/vnd.ms-fontobject image/svg+xml;

    client_max_body_size 256M;
    fastcgi_read_timeout 300;

    limit_req_zone \$binary_remote_addr zone=global:10m rate=30r/s;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
NGINXEOF

    cat > /etc/nginx/sites-available/default <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html;
    index index.html;
    server_name _;
    server_tokens off;
    location / { try_files $uri $uri/ =404; }
}
EOF

    cat > /var/www/html/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SERVER UP</title>
    <meta name="robots" content="noindex, nofollow">
    <link rel="icon" type="image/svg+xml"
        href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'%3E%3Ccircle cx='50' cy='50' r='45' fill='%2322c55e'/%3E%3C/svg%3E">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
            background: #ffffff;
            min-height: 100vh;
            display: flex;
            justify-content: center;
            align-items: center;
            color: #1a1a1a;
        }
        .container { text-align: center; animation: fadeIn 1s ease-in; }
        .server-container { position: relative; margin-bottom: 0.3rem; }
        .server-svg { width: 250px; height: 100px; }
        .led {
            fill: #22c55e;
            filter: drop-shadow(0 0 4px rgba(34, 197, 94, 0.9));
            animation: pulseFixed 2s ease-in-out infinite;
        }
        circle.led:nth-of-type(1) { animation-delay: 0s; animation-duration: 2s; }
        circle.led:nth-of-type(2) { animation-delay: 0.6s; animation-duration: 2.3s; }
        @keyframes pulseFixed {
            0%, 100% { opacity: 0.3; filter: drop-shadow(0 0 2px rgba(34, 197, 94, 0.3)); }
            50%       { opacity: 1;   filter: drop-shadow(0 0 6px rgba(34, 197, 94, 1)); }
        }
        .status-text {
            font-size: 1.5rem;
            font-weight: 300;
            letter-spacing: 4px;
            text-transform: uppercase;
            color: #666;
            margin-top: -0.5rem;
            animation: fadeInUp 1s ease-out 0.3s both;
        }
        .host-text {
            font-size: 0.75rem;
            font-weight: 400;
            color: #999;
            margin-top: 0.5rem;
            animation: fadeInUp 1s ease-out 0.5s both;
        }
        @keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
        @keyframes fadeInUp {
            from { opacity: 0; transform: translateY(20px); }
            to   { opacity: 1; transform: translateY(0); }
        }
        @media (max-width: 600px) {
            .server-svg { width: 200px; height: 80px; }
            .status-text { font-size: 1.2rem; letter-spacing: 3px; }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="server-container">
            <svg class="server-svg" viewBox="0 0 250 100" xmlns="http://www.w3.org/2000/svg">
                <rect x="25" y="27.5" width="200" height="45" rx="4" fill="none" stroke="#1a1a1a" stroke-width="2.5" />
                <rect x="35" y="35.5" width="180" height="29" rx="2" fill="none" stroke="#1a1a1a" stroke-width="1.5" />
                <circle cx="50" cy="50" r="6" fill="none" stroke="#999" stroke-width="1.5" />
                <path d="M 50 46 L 50 50" stroke="#999" stroke-width="1.5" stroke-linecap="round" />
                <circle class="led" cx="185" cy="50" r="3.5" />
                <circle class="led" cx="200" cy="50" r="3.5" />
            </svg>
        </div>
        <div class="status-text">Server Up</div>
        <div class="host-text" id="host-label"></div>
    </div>
    <script>
        var h = window.location.hostname;
        var isIP = /^(\d{1,3}\.){3}\d{1,3}$/.test(h) || /^[0-9a-fA-F:]+$/.test(h);
        document.getElementById('host-label').textContent = isIP ? h : h + ' is not configured';
    </script>
</body>
</html>
EOF

    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-enabled/default.bak
    systemctl start nginx
    systemctl enable nginx

    echo -e "${GREEN}✓ Nginx${NC}"
}

# ── FIREWALL & FAIL2BAN ──────────────────────────────────────

install_firewall() {
    step_msg "Installing firewall & fail2ban..."

    apt-get install -y -qq fail2ban ufw

    cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 3600
banaction = iptables-multiport
maxretry = 5

[sshd]
enabled = true
port = ssh
logpath = /var/log/auth.log
maxretry = 5
EOF

    systemctl restart fail2ban
    systemctl enable fail2ban

    ufw default deny incoming &>/dev/null
    ufw default allow outgoing &>/dev/null
    ufw allow 22/tcp &>/dev/null
    ufw allow 80/tcp &>/dev/null
    ufw allow 443/tcp &>/dev/null
    ufw --force enable &>/dev/null

    echo -e "${GREEN}✓ Firewall & fail2ban${NC}"

    # PAM auth notifications (sudo + SSH login alerts)
    if [[ -x /usr/local/bin/cipi-auth-notify ]]; then
        if ! grep -q 'cipi-auth-notify' /etc/pam.d/sudo 2>/dev/null; then
            echo 'session optional pam_exec.so seteuid /usr/local/bin/cipi-auth-notify' >> /etc/pam.d/sudo
        fi
        if ! grep -q 'cipi-auth-notify' /etc/pam.d/sshd 2>/dev/null; then
            echo 'session optional pam_exec.so seteuid /usr/local/bin/cipi-auth-notify' >> /etc/pam.d/sshd
        fi
        echo -e "${GREEN}✓ PAM auth notifications${NC}"
    fi
}

# ── MARIADB ───────────────────────────────────────────────────

install_mariadb() {
    step_msg "Installing MariaDB..."

    # MariaDB official repo for latest stable
    curl -fsSL https://mariadb.org/mariadb_release_signing_key.pgp | gpg --dearmor -o /usr/share/keyrings/mariadb-keyring.gpg 2>/dev/null

    echo "deb [signed-by=/usr/share/keyrings/mariadb-keyring.gpg] https://dlm.mariadb.com/repo/mariadb-server/11.4/repo/ubuntu $(lsb_release -cs) main" > /etc/apt/sources.list.d/mariadb.list

    apt-get update -qq
    apt-get install -y -qq mariadb-server mariadb-client

    # Generate root password
    local DB_ROOT_PASS
    DB_ROOT_PASS=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32)

    # Secure installation
    mysql <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

    # Tune based on available RAM
    local RAM_MB
    RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    local BUFFER_POOL="256M"
    [ "$RAM_MB" -ge 2048 ] && BUFFER_POOL="512M"
    [ "$RAM_MB" -ge 4096 ] && BUFFER_POOL="1G"
    [ "$RAM_MB" -ge 8192 ] && BUFFER_POOL="2G"
    [ "$RAM_MB" -ge 16384 ] && BUFFER_POOL="4G"

    cat > /etc/mysql/mariadb.conf.d/99-cipi.cnf <<CNFEOF
[mysqld]
bind-address = 127.0.0.1
innodb_buffer_pool_size = ${BUFFER_POOL}
innodb_log_file_size = 256M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
max_connections = 100
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
skip-name-resolve
CNFEOF

    systemctl restart mariadb
    systemctl enable mariadb

    # Save config
    mkdir -p /etc/cipi
    chmod 700 /etc/cipi
    echo "{\"db_root_password\": \"${DB_ROOT_PASS}\"}" > /etc/cipi/server.json
    chmod 600 /etc/cipi/server.json

    echo -e "${GREEN}✓ MariaDB 11.4 (buffer_pool: ${BUFFER_POOL})${NC}"
}

# ── REDIS ───────────────────────────────────────────────────

install_redis() {
    step_msg "Installing Redis..."

    apt-get install -y -qq redis-server

    # Generate password
    local REDIS_PASS
    REDIS_PASS=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 32)

    # Configure requirepass and bind to localhost
    if grep -q "^# *requirepass" /etc/redis/redis.conf; then
        sed -i "s/^# *requirepass.*/requirepass ${REDIS_PASS}/" /etc/redis/redis.conf
    elif grep -q "^requirepass" /etc/redis/redis.conf; then
        sed -i "s/^requirepass.*/requirepass ${REDIS_PASS}/" /etc/redis/redis.conf
    else
        echo "requirepass ${REDIS_PASS}" >> /etc/redis/redis.conf
    fi

    # Ensure bind to localhost only
    if grep -q "^bind " /etc/redis/redis.conf; then
        sed -i "s/^bind .*/bind 127.0.0.1 -::1/" /etc/redis/redis.conf
    elif ! grep -q "^bind " /etc/redis/redis.conf; then
        echo "bind 127.0.0.1 -::1" >> /etc/redis/redis.conf
    fi

    systemctl restart redis-server
    systemctl enable redis-server

    # Save Redis credentials in server.json (merge with existing)
    local tmp
    tmp=$(mktemp)
    jq --arg u "default" --arg p "$REDIS_PASS" '. + {redis_user: $u, redis_password: $p}' /etc/cipi/server.json > "$tmp"
    mv "$tmp" /etc/cipi/server.json
    chmod 600 /etc/cipi/server.json

    echo -e "${GREEN}✓ Redis $(redis-server --version 2>/dev/null | awk '{print $3}' || echo "")${NC}"
}

# ── PHP (multi-version) ──────────────────────────────────────

install_php() {
    step_msg "Installing PHP 8.4, 8.5..."

    add-apt-repository -y ppa:ondrej/php &>/dev/null
    apt-get update -qq

    local EXTENSIONS="fpm common cli curl bcmath mbstring mysql sqlite3 pgsql memcached zip xml soap gd imagick intl"

    for VER in 8.4 8.5; do
        echo -e "${CYAN}→ PHP ${VER}...${NC}"

        local PACKAGES=""
        for EXT in $EXTENSIONS; do
            PACKAGES+=" php${VER}-${EXT}"
        done
        apt-get install -y -qq $PACKAGES

        # Cipi defaults
        cat > "/etc/php/${VER}/fpm/conf.d/99-cipi.ini" <<INIEOF
memory_limit = 256M
upload_max_filesize = 256M
post_max_size = 256M
max_execution_time = 300
max_input_time = 300
expose_php = Off
INIEOF

        # Replace default www pool with a minimal placeholder so FPM can start
        cat > "/etc/php/${VER}/fpm/pool.d/www.conf" <<POOLEOF
[www]
user = www-data
group = www-data
listen = /run/php/php${VER}-fpm.sock
listen.owner = www-data
listen.group = www-data
pm = ondemand
pm.max_children = 2
pm.process_idle_timeout = 10s
POOLEOF

        systemctl restart "php${VER}-fpm"
        systemctl enable "php${VER}-fpm"
    done

    # Set 8.5 as default CLI
    update-alternatives --set php /usr/bin/php8.5 2>/dev/null || true

    echo -e "${GREEN}✓ PHP 8.4, 8.5${NC}"
}

# ── COMPOSER ──────────────────────────────────────────────────

install_composer() {
    step_msg "Installing Composer..."

    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer --quiet

    echo -e "${GREEN}✓ Composer$(composer --version 2>/dev/null | awk '{print " "$3}')${NC}"
}

# ── DEPLOYER ──────────────────────────────────────────────────

install_deployer() {
    step_msg "Installing Deployer..."

    curl -fsSL https://deployer.org/deployer.phar -o /usr/local/bin/dep
    chmod 755 /usr/local/bin/dep

    echo -e "${GREEN}✓ Deployer$(dep --version 2>/dev/null | awk '{print " "$2}')${NC}"
}

# ── NODE.JS ───────────────────────────────────────────────────

install_nodejs() {
    step_msg "Installing Node.js..."

    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - &>/dev/null
    apt-get install -y -qq nodejs

    echo -e "${GREEN}✓ Node.js $(node -v 2>/dev/null)${NC}"
}

# ── SUPERVISOR ────────────────────────────────────────────────

install_supervisor() {
    step_msg "Installing Supervisor..."

    apt-get install -y -qq supervisor
    systemctl enable supervisor
    systemctl start supervisor

    echo -e "${GREEN}✓ Supervisor${NC}"
}

# ── LET'S ENCRYPT ─────────────────────────────────────────────

install_certbot() {
    step_msg "Installing Certbot..."

    apt-get install -y -qq certbot python3-certbot-nginx

    echo -e "${GREEN}✓ Certbot${NC}"
}

# ── CIPI CLI ──────────────────────────────────────────────────

install_cipi() {
    step_msg "Installing Cipi CLI..."

    mkdir -p /opt/cipi/{lib,templates}
    mkdir -p /etc/cipi
    mkdir -p /var/log/cipi
    chmod 700 /etc/cipi

    cd /tmp
    rm -rf cipi-install
    git clone -b "$BRANCH" --depth 1 "https://github.com/${REPO}.git" cipi-install 2>/dev/null

    BUILD="$(tr -d '[:space:]' < /tmp/cipi-install/version.md 2>/dev/null)"
    [[ -z "$BUILD" ]] && { echo "Cannot read version.md from repo"; exit 1; }

    # Main CLI
    cp cipi-install/cipi /usr/local/bin/cipi
    chmod 700 /usr/local/bin/cipi

    # Lib scripts
    cp cipi-install/lib/*.sh /opt/cipi/lib/
    chmod 700 /opt/cipi/lib/*.sh

    # Cipi API package (for cipi api)
    if [ -d "cipi-install/cipi-api" ]; then
        rm -rf /opt/cipi/cipi-api 2>/dev/null
        cp -a cipi-install/cipi-api /opt/cipi/cipi-api
    fi

    # Worker helper
    cp cipi-install/lib/cipi-worker.sh /usr/local/bin/cipi-worker
    chmod 700 /usr/local/bin/cipi-worker

    # Cron notification wrapper
    cp cipi-install/lib/cipi-cron-notify.sh /usr/local/bin/cipi-cron-notify
    chmod 700 /usr/local/bin/cipi-cron-notify

    # PAM auth notification script
    cp cipi-install/lib/cipi-auth-notify.sh /usr/local/bin/cipi-auth-notify
    chmod 700 /usr/local/bin/cipi-auth-notify

    # Templates (if any)
    cp cipi-install/templates/* /opt/cipi/templates/ 2>/dev/null || true

    chown -R root:root /usr/local/bin/cipi /usr/local/bin/cipi-worker /usr/local/bin/cipi-cron-notify /usr/local/bin/cipi-auth-notify /opt/cipi

    # Generate vault key for config encryption
    if [ ! -f /etc/cipi/.vault_key ]; then
        openssl rand -base64 32 > /etc/cipi/.vault_key
        chmod 400 /etc/cipi/.vault_key
    fi

    # Source vault functions now that lib is installed
    CIPI_LIB="/opt/cipi/lib" CIPI_CONFIG="/etc/cipi" source /opt/cipi/lib/vault.sh

    # Init config files (encrypted)
    for f in apps.json databases.json; do
        if [ ! -f "/etc/cipi/$f" ]; then
            echo "{}" | vault_write "$f"
        fi
    done

    # Seal any config files written in plaintext earlier in setup
    for f in server.json; do
        [ -f "/etc/cipi/$f" ] && vault_seal "$f"
    done

    # Version
    echo "$BUILD" > /etc/cipi/version

    # Sudoers for API (www-data runs cipi via sudo)
    if [ ! -f /etc/sudoers.d/cipi-api ]; then
        echo 'www-data ALL=(root) NOPASSWD: /usr/local/bin/cipi *' > /etc/sudoers.d/cipi-api
        chmod 440 /etc/sudoers.d/cipi-api
    fi

    rm -rf /tmp/cipi-install

    echo -e "${GREEN}✓ Cipi CLI v${BUILD}${NC}"
}

# ── CRON JOBS ─────────────────────────────────────────────────

setup_cron() {
    step_msg "Setting up cron jobs..."

    mkdir -p /var/log/cipi

    # Configure unattended-upgrades: security patches only,
    # never auto-upgrade nginx / mariadb / redis / php (managed by cipi)
    cat > /etc/apt/apt.conf.d/50cipi-unattended-upgrades <<'UUEOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {
    "nginx";
    "nginx-core";
    "nginx-full";
    "nginx-extras";
    "mariadb-server";
    "mariadb-client";
    "mariadb-common";
    "redis-server";
    "php.*";
    "libphp.*";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Dpkg::Options {
    "--force-confdef";
    "--force-confold";
};
UUEOF

    # Enable periodic security updates
    cat > /etc/apt/apt.conf.d/20cipi-auto-upgrades <<'AUEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUEOF

    (crontab -l 2>/dev/null | grep -v "CIPI"; cat <<'CRONEOF'
# === CIPI CRON JOBS ===
# Cipi self-update (daily 3:50 AM)
50 3 * * * /usr/local/bin/cipi-cron-notify self-update /usr/local/bin/cipi self-update >> /var/log/cipi/cipi.log 2>&1
# SSL renewal (Sunday 4 AM)
10 4 * * 0 /usr/local/bin/cipi-cron-notify ssl-renew certbot renew --nginx --non-interactive --post-hook "systemctl reload nginx" >> /var/log/cipi/certbot.log 2>&1
# Security updates — unattended-upgrades handles this daily via APT::Periodic
# Weekly apt cache cleanup (Sunday 5 AM)
0 5 * * 0 apt-get clean && apt-get autoclean >> /var/log/cipi/updates.log 2>&1
# Clear RAM cache (daily 5:50 AM)
50 5 * * * echo 3 > /proc/sys/vm/drop_caches && swapoff -a && swapon -a 2>/dev/null
CRONEOF
    ) | crontab -

    # ── GDPR-compliant log rotation ──

    # Application logs (Laravel, PHP-FPM, workers, deploy) — 12 months
    cat > /etc/logrotate.d/cipi-app-logs <<'EOF'
/home/*/shared/storage/logs/*.log
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
    create 0640 root root
}
EOF

    # HTTP / Navigation logs (nginx access & error) — 90 days
    cat > /etc/logrotate.d/cipi-http-logs <<'EOF'
/home/*/logs/nginx-access.log
/home/*/logs/nginx-error.log
/var/log/nginx/*.log {
    daily
    missingok
    rotate 90
    compress
    delaycompress
    notifempty
    create 0640 root adm
    sharedscripts
    postrotate
        [ -f /var/run/nginx.pid ] && kill -USR1 $(cat /var/run/nginx.pid) 2>/dev/null || true
    endscript
}
EOF

    # Security logs (firewall, fail2ban, auth) — 12 months
    cat > /etc/logrotate.d/cipi-security-logs <<'EOF'
/var/log/fail2ban.log {
    daily
    missingok
    rotate 365
    compress
    delaycompress
    notifempty
    create 0640 root adm
    postrotate
        fail2ban-client flushlogs >/dev/null 2>&1 || true
    endscript
}
/var/log/ufw.log {
    daily
    missingok
    rotate 365
    compress
    delaycompress
    notifempty
    create 0640 syslog adm
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate 2>/dev/null || invoke-rc.d rsyslog rotate >/dev/null 2>&1 || true
    endscript
}
/var/log/auth.log {
    daily
    missingok
    rotate 365
    compress
    delaycompress
    notifempty
    create 0640 syslog adm
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate 2>/dev/null || invoke-rc.d rsyslog rotate >/dev/null 2>&1 || true
    endscript
}
EOF

    # Remove conflicting system logrotate configs
    rm -f /etc/logrotate.d/cipi-apps
    rm -f /etc/logrotate.d/nginx
    rm -f /etc/logrotate.d/fail2ban

    echo -e "${GREEN}✓ Cron jobs & GDPR log rotation${NC}"
}

# ── FINAL ─────────────────────────────────────────────────────

final_summary() {
    clear

    local SERVER_IP
    SERVER_IP=$(curl -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null || echo "N/A")
    CIPI_LIB="/opt/cipi/lib" CIPI_CONFIG="/etc/cipi" source /opt/cipi/lib/vault.sh
    local _sj; _sj=$(vault_read server.json)
    local DB_ROOT_PASS
    DB_ROOT_PASS=$(echo "$_sj" | jq -r '.db_root_password')
    local REDIS_USER REDIS_PASS
    REDIS_USER=$(echo "$_sj" | jq -r '.redis_user // "default"')
    REDIS_PASS=$(echo "$_sj" | jq -r '.redis_password // ""')

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${GREEN}${BOLD}CIPI v${BUILD} INSTALLED SUCCESSFULLY${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "  ${BOLD}Server${NC}"
    echo -e "  IP:             ${CYAN}${SERVER_IP}${NC}"
    echo -e "  OS:             ${CYAN}Ubuntu $(lsb_release -rs)${NC}"
    echo ""
    echo -e "  ${BOLD}Stack${NC}"
    echo -e "  Nginx:          ${CYAN}$(nginx -v 2>&1 | awk -F/ '{print $2}')${NC}"
    echo -e "  MariaDB:        ${CYAN}$(mysql --version 2>/dev/null | awk '{print $5}' | tr -d ',')${NC}"
    echo -e "  Redis:          ${CYAN}$(redis-server --version 2>/dev/null | awk '{print $3}' || echo "N/A")${NC}"
    echo -e "  PHP:            ${CYAN}8.4, 8.5${NC}"
    echo -e "  Node.js:        ${CYAN}$(node -v 2>/dev/null)${NC}"
    echo -e "  Composer:       ${CYAN}$(composer --version 2>/dev/null | awk '{print $3}')${NC}"
    echo -e "  Deployer:       ${CYAN}$(dep --version 2>/dev/null | awk '{print $2}')${NC}"
    echo ""
    echo -e "  ${BOLD}MariaDB Root${NC}"
    echo -e "  User:           ${CYAN}root${NC}"
    echo -e "  Password:       ${CYAN}${DB_ROOT_PASS}${NC}"
    echo ""
    if [[ -n "$REDIS_PASS" ]]; then
    echo -e "  ${BOLD}Redis${NC}"
    echo -e "  User:           ${CYAN}${REDIS_USER}${NC}"
    echo -e "  Password:       ${CYAN}${REDIS_PASS}${NC}"
    echo ""
    fi
    echo -e "  ${YELLOW}${BOLD}⚠ SAVE THESE PASSWORDS!${NC}"
    echo ""
    echo -e "  ${BOLD}Getting Started${NC}"
    echo -e "  Server status:  ${CYAN}cipi status${NC}"
    echo -e "  All commands:   ${CYAN}cipi help${NC}"
    echo -e "  Create app:     ${CYAN}cipi app create${NC}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# ── MAIN ──────────────────────────────────────────────────────

main() {
    # Fetch version early for logo display
    BUILD=$(curl -fsSL "https://raw.githubusercontent.com/${REPO}/refs/heads/${BRANCH}/version.md" 2>/dev/null | tr -d '[:space:]')
    [[ -z "$BUILD" ]] && BUILD="?"

    show_logo
    check_requirements
    install_basics
    setup_swap
    setup_system
    install_nginx
    install_firewall
    install_mariadb
    install_php
    install_composer
    install_deployer
    install_nodejs
    install_supervisor
    install_redis
    install_certbot
    install_cipi
    setup_cron
    final_summary
}

main
