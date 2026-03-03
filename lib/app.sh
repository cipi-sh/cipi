#!/bin/bash
#############################################
# Cipi — Application Management
#############################################

# ── CREATE ────────────────────────────────────────────────────

app_create() {
    parse_args "$@"
    local app_user="${ARG_user:-}" domain="${ARG_domain:-}" repository="${ARG_repository:-}"
    local branch="${ARG_branch:-main}" php_ver="${ARG_php:-8.4}"

    # Interactive prompts for missing fields
    [[ -z "$app_user" ]]    && read_input "App username (lowercase, min 3 chars)" "" app_user
    [[ -z "$domain" ]]      && read_input "Primary domain" "" domain
    [[ -z "$repository" ]]  && read_input "Git repository URL (SSH)" "" repository
    read_input "Branch" "$branch" branch
    read_input "PHP version" "$php_ver" php_ver

    # Validate
    validate_username "$app_user"  || { error "Invalid username '${app_user}'"; exit 1; }
    validate_domain "$domain"      || { error "Invalid domain '${domain}'"; exit 1; }
    validate_php_version "$php_ver" || { error "Invalid PHP version. Use: 8.4 8.5"; exit 1; }
    php_is_installed "$php_ver"    || { error "PHP $php_ver not installed. Run: cipi php install $php_ver"; exit 1; }
    app_exists "$app_user"         && { error "App '${app_user}' already exists"; exit 1; }
    id "$app_user" &>/dev/null     && { error "User '${app_user}' already exists"; exit 1; }

    echo ""; info "Creating '${app_user}'..."; echo ""

    local user_pass db_pass webhook_token app_key home
    user_pass=$(generate_password 24)
    db_pass=$(generate_password 32)
    webhook_token=$(generate_token)
    app_key=$(generate_app_key)
    home="/home/${app_user}"

    # 1. Linux user
    step "Creating user..."
    useradd -m -s /bin/bash -G www-data "$app_user"
    echo "${app_user}:${user_pass}" | chpasswd
    chmod 750 "$home"
    usermod -aG "$app_user" www-data
    success "User"

    # 2. Directories
    step "Directories..."
    mkdir -p "${home}"/{shared/storage/{app/public,framework/{cache/data,sessions,views},logs},logs,.ssh,.deployer}
    cat > "${home}/.bashrc" <<BASH
export PATH="/usr/local/bin:\$PATH"
alias php='/usr/bin/php${php_ver}'
alias artisan='php ${home}/current/artisan'
alias composer='/usr/local/bin/composer'
alias tinker='artisan tinker'
alias deploy='dep deploy -f ${home}/.deployer/deploy.php'
PS1='\[\033[0;32m\]\u\[\033[0m\]@\h:\[\033[0;34m\]\w\[\033[0m\]\$ '
BASH
    chown -R "${app_user}:${app_user}" "$home"
    success "Directories"

    # 3. SSH deploy key (for GitHub) + authorized_keys (for Deployer localhost SSH)
    step "Deploy key..."
    sudo -u "$app_user" ssh-keygen -t ed25519 -C "${app_user}@cipi" -f "${home}/.ssh/id_ed25519" -N "" -q
    local deploy_key; deploy_key=$(cat "${home}/.ssh/id_ed25519.pub")
    echo "$deploy_key" >> "${home}/.ssh/authorized_keys"
    chown "${app_user}:${app_user}" "${home}/.ssh/authorized_keys"
    chmod 600 "${home}/.ssh/authorized_keys"
    ssh-keyscan -H github.com gitlab.com 2>/dev/null >> "${home}/.ssh/known_hosts"
    chown "${app_user}:${app_user}" "${home}/.ssh/known_hosts"
    chmod 600 "${home}/.ssh/known_hosts"
    success "Deploy key"

    # 4. MariaDB database
    step "Database..."
    local db_root; db_root=$(get_db_root_password)
    mariadb -u root -p"${db_root}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${app_user}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${app_user}'@'localhost' IDENTIFIED BY '${db_pass}';
CREATE USER IF NOT EXISTS '${app_user}'@'127.0.0.1' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON \`${app_user}\`.* TO '${app_user}'@'localhost';
GRANT ALL PRIVILEGES ON \`${app_user}\`.* TO '${app_user}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
    success "Database"

    # 5. .env (auto-compiled by Cipi)
    step ".env..."
    cat > "${home}/shared/.env" <<ENV
APP_NAME="${app_user}"
APP_ENV=production
APP_KEY=${app_key}
APP_DEBUG=false
APP_URL=https://${domain}

LOG_CHANNEL=daily
LOG_LEVEL=error

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${app_user}
DB_USERNAME=${app_user}
DB_PASSWORD=${db_pass}

BROADCAST_CONNECTION=log
CACHE_STORE=database
SESSION_DRIVER=database
QUEUE_CONNECTION=database

MAIL_MAILER=log

CIPI_WEBHOOK_TOKEN=${webhook_token}
CIPI_APP_USER=${app_user}
CIPI_PHP_VERSION=${php_ver}
ENV
    chown "${app_user}:${app_user}" "${home}/shared/.env"
    chmod 640 "${home}/shared/.env"
    success ".env with DB + webhook"

    # 6. PHP-FPM pool
    step "PHP-FPM pool..."
    _create_fpm_pool "$app_user" "$php_ver"
    reload_php_fpm "$php_ver"
    success "PHP-FPM ${php_ver}"

    # 7. Nginx vhost
    step "Nginx vhost..."
    _create_nginx_vhost "$app_user" "$domain" "$php_ver" ""
    ln -sf "/etc/nginx/sites-available/${app_user}" "/etc/nginx/sites-enabled/${app_user}"
    reload_nginx
    success "Nginx → ${domain}"

    # 8. Save config early (so app is registered even if later steps fail)
    app_save "$app_user" "$(cat <<JSON
{
    "user": "${app_user}",
    "domain": "${domain}",
    "aliases": [],
    "repository": "${repository}",
    "branch": "${branch}",
    "php": "${php_ver}",
    "webhook_token": "${webhook_token}",
    "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
JSON
)"
    log_action "APP CREATED: $app_user domain=$domain php=$php_ver"

    # 9. Supervisor default worker
    step "Queue worker..."
    echo "" > "/etc/supervisor/conf.d/${app_user}.conf"
    _create_supervisor_worker "$app_user" "$php_ver" "default"
    reload_supervisor
    success "Worker (default queue)"

    # 10. Crontab
    step "Crontab..."
    cat <<CRON | crontab -u "$app_user" -
# Laravel Scheduler
* * * * * /usr/bin/php${php_ver} ${home}/current/artisan schedule:run >> /dev/null 2>&1
# Cipi deploy trigger (written by cipi/agent webhook)
* * * * * test -f ${home}/.deploy-trigger && rm -f ${home}/.deploy-trigger && cd ${home} && /usr/local/bin/dep deploy -f ${home}/.deployer/deploy.php >> ${home}/logs/deploy.log 2>&1
CRON
    success "Scheduler + deploy trigger"

    # 11. Deployer config
    step "Deployer..."
    _create_deployer_config "$app_user" "$repository" "$branch" "$php_ver"
    success "Deployer"

    # 12. Sudoers (worker restart only)
    step "Permissions..."
    cat > "/etc/sudoers.d/cipi-${app_user}" <<SUDO
${app_user} ALL=(root) NOPASSWD: /usr/local/bin/cipi-worker restart ${app_user}
${app_user} ALL=(root) NOPASSWD: /usr/local/bin/cipi-worker status ${app_user}
SUDO
    chmod 440 "/etc/sudoers.d/cipi-${app_user}"
    success "Permissions"

    # Summary
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${GREEN}${BOLD}APP CREATED: ${app_user}${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  Domain:     ${CYAN}${domain}${NC}"
    echo -e "  PHP:        ${CYAN}${php_ver}${NC}"
    echo -e "  Home:       ${CYAN}${home}${NC}"
    echo ""
    echo -e "  ${BOLD}SSH${NC}         ${CYAN}${app_user}${NC} / ${CYAN}${user_pass}${NC}"
    echo -e "  ${BOLD}Database${NC}    ${CYAN}${app_user}${NC} / ${CYAN}${db_pass}${NC}"
    echo ""
    echo -e "  ${BOLD}Deploy Key${NC}  (add to your Git provider)"
    echo -e "  ${CYAN}${deploy_key}${NC}"
    echo ""
    echo -e "  ${BOLD}Webhook${NC}     ${CYAN}https://${domain}/cipi/webhook${NC}"
    echo -e "  ${BOLD}Token${NC}       ${CYAN}${webhook_token}${NC}"
    echo ""
    echo -e "  ${BOLD}Next:${NC} composer require cipi/agent  (in your Laravel project)"
    echo -e "        cipi deploy ${app_user}"
    echo -e "        cipi ssl install ${app_user}"
    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠ SAVE THESE CREDENTIALS — shown only once${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── LIST ──────────────────────────────────────────────────────

app_list() {
    if [[ ! -f "${CIPI_CONFIG}/apps.json" ]] || [[ $(jq 'length' "${CIPI_CONFIG}/apps.json") -eq 0 ]]; then
        info "No apps. Create one: cipi app create"; return
    fi
    printf "\n${BOLD}%-14s %-28s %-6s %s${NC}\n" "APP" "DOMAIN" "PHP" "CREATED"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    jq -r 'to_entries[]|"\(.key)\t\(.value.domain)\t\(.value.php)\t\(.value.created_at)"' \
        "${CIPI_CONFIG}/apps.json" | while IFS=$'\t' read -r a d p c; do
        local st="${GREEN}●${NC}"
        systemctl is-active --quiet "php${p}-fpm" 2>/dev/null || st="${RED}●${NC}"
        printf "  ${st} %-12s %-28s %-6s %s\n" "$a" "$d" "$p" "${c:0:10}"
    done; echo ""
}

# ── SHOW ──────────────────────────────────────────────────────

app_show() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi app show <app>"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }

    local d p b repo wt ca aliases
    d=$(app_get "$app" domain); p=$(app_get "$app" php); b=$(app_get "$app" branch)
    repo=$(app_get "$app" repository)
    wt=$(app_get "$app" webhook_token); ca=$(app_get "$app" created_at)
    aliases=$(jq -r --arg a "$app" '.[$a].aliases//[]|join(", ")' "${CIPI_CONFIG}/apps.json")
    [[ -z "$aliases" ]] && aliases="none"

    echo -e "\n${BOLD}${app}${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-14s ${CYAN}%s${NC}\n" "Domain" "$d"
    printf "  %-14s ${CYAN}%s${NC}\n" "Aliases" "$aliases"
    printf "  %-14s ${CYAN}%s${NC}\n" "Repository" "$repo"
    printf "  %-14s ${CYAN}%s${NC}\n" "Branch" "$b"
    printf "  %-14s ${CYAN}%s${NC}\n" "PHP" "$p"
    printf "  %-14s ${CYAN}%s${NC}\n" "Created" "$ca"
    echo -e "\n  ${BOLD}Webhook${NC}  ${CYAN}https://${d}/cipi/webhook${NC}"

    if [[ -f "/home/${app}/.ssh/id_ed25519.pub" ]]; then
        echo -e "\n  ${BOLD}Deploy Key${NC}\n  ${CYAN}$(cat "/home/${app}/.ssh/id_ed25519.pub")${NC}"
    fi
    if [[ -L "/home/${app}/current" ]]; then
        echo -e "\n  ${BOLD}Release${NC}  ${CYAN}$(readlink -f "/home/${app}/current" | xargs basename)${NC}"
    fi
    echo -e "\n  ${BOLD}Workers${NC}"
    supervisorctl status "${app}-worker-*" 2>/dev/null | sed 's/^/  /' || echo "  none"
    echo ""
}

# ── EDIT ──────────────────────────────────────────────────────

app_edit() {
    local app="${1:-}"; shift || true
    [[ -z "$app" ]] && { error "Usage: cipi app edit <app> [--php=X.Y] [--branch=B] [--repository=URL]"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    parse_args "$@"
    local changed=false cur_php; cur_php=$(app_get "$app" php)

    if [[ -n "${ARG_php:-}" ]]; then
        local np="${ARG_php}"
        validate_php_version "$np" || { error "Invalid PHP: $np"; exit 1; }
        php_is_installed "$np" || { error "PHP $np not installed"; exit 1; }
        step "PHP ${cur_php} → ${np}..."
        rm -f "/etc/php/${cur_php}/fpm/pool.d/${app}.conf"
        _create_fpm_pool "$app" "$np"; reload_php_fpm "$cur_php"; reload_php_fpm "$np"
        local dom; dom=$(app_get "$app" domain)
        _create_nginx_vhost "$app" "$dom" "$np"; reload_nginx
        sed -i "s|/usr/bin/php[0-9]\.[0-9]|/usr/bin/php${np}|g" "/etc/supervisor/conf.d/${app}.conf" 2>/dev/null
        reload_supervisor
        crontab -u "$app" -l 2>/dev/null | sed "s|php${cur_php}|php${np}|g" | crontab -u "$app" -
        sed -i "s|php${cur_php}|php${np}|g" "/home/${app}/.bashrc" "/home/${app}/.deployer/deploy.php" 2>/dev/null
        sed -i "s|^CIPI_PHP_VERSION=.*|CIPI_PHP_VERSION=${np}|" "/home/${app}/shared/.env"
        app_set "$app" php "$np"; success "PHP → $np"; changed=true
    fi
    if [[ -n "${ARG_branch:-}" ]]; then
        app_set "$app" branch "${ARG_branch}"
        sed -i "s|set('branch', '.*')|set('branch', '${ARG_branch}')|" "/home/${app}/.deployer/deploy.php"
        success "Branch → ${ARG_branch}"; changed=true
    fi
    if [[ -n "${ARG_repository:-}" ]]; then
        app_set "$app" repository "${ARG_repository}"
        sed -i "s|set('repository', '.*')|set('repository', '${ARG_repository}')|" "/home/${app}/.deployer/deploy.php"
        success "Repository updated"; changed=true
    fi
    [[ "$changed" == false ]] && info "Nothing changed. Use --php, --branch, or --repository"
    [[ "$changed" == true ]] && log_action "APP EDITED: $app $*"
}

# ── DELETE ────────────────────────────────────────────────────

app_delete() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi app delete <app>"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    local d; d=$(app_get "$app" domain); local p; p=$(app_get "$app" php)

    echo ""; warn "Will permanently delete: user, home, database, vhost, workers, SSL"
    confirm "Delete '${app}'?" || { info "Cancelled"; return; }

    step "Workers...";     supervisorctl stop "${app}-worker-*" 2>/dev/null||true; rm -f "/etc/supervisor/conf.d/${app}.conf"; reload_supervisor
    step "Nginx...";       rm -f "/etc/nginx/sites-enabled/${app}" "/etc/nginx/sites-available/${app}"; reload_nginx
    step "PHP-FPM...";     rm -f "/etc/php/${p}/fpm/pool.d/${app}.conf"; reload_php_fpm "$p" 2>/dev/null||true
    step "Database...";    local dbr; dbr=$(get_db_root_password); mariadb -u root -p"$dbr" -e "DROP DATABASE IF EXISTS \`${app}\`; DROP USER IF EXISTS '${app}'@'localhost'; DROP USER IF EXISTS '${app}'@'127.0.0.1'; FLUSH PRIVILEGES;" 2>/dev/null||true
    step "Crontab...";     crontab -u "$app" -r 2>/dev/null||true
    step "Sudoers...";     rm -f "/etc/sudoers.d/cipi-${app}"
    step "SSL...";         certbot delete --cert-name "$d" --non-interactive 2>/dev/null||true
    step "User & files..."; userdel -r "$app" 2>/dev/null||true
    step "Config...";      app_remove "$app"

    log_action "APP DELETED: $app"
    echo ""; success "'${app}' deleted"; echo ""
}

# ── ENV / LOGS / TINKER / ARTISAN ─────────────────────────────

app_env() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi app env <app>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    ${EDITOR:-nano} "/home/${app}/shared/.env"
    chown "${app}:${app}" "/home/${app}/shared/.env"; chmod 640 "/home/${app}/shared/.env"
    success ".env updated"
}

app_logs() {
    local app="${1:-}"; shift||true
    [[ -z "$app" ]] && { error "Usage: cipi app logs <app> [--type=nginx|php|worker|deploy|all]"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    parse_args "$@"
    case "${ARG_type:-all}" in
        nginx)  tail -f "/home/${app}/logs/nginx-"*.log ;;
        php)    tail -f "/home/${app}/logs/php-fpm-"*.log ;;
        worker) tail -f "/home/${app}/logs/worker-"*.log ;;
        deploy) tail -f "/home/${app}/logs/deploy.log" ;;
        all)    tail -f "/home/${app}/logs/"*.log ;;
    esac
}

app_tinker() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi app tinker <app>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    local p; p=$(app_get "$app" php)
    sudo -u "$app" /usr/bin/php"$p" "/home/${app}/current/artisan" tinker
}

app_artisan() {
    local app="${1:-}"; shift||true
    [[ -z "$app" ]] && { error "Usage: cipi app artisan <app> <cmd>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    [[ $# -eq 0 ]] && { error "No artisan command"; exit 1; }
    local p; p=$(app_get "$app" php)
    sudo -u "$app" /usr/bin/php"$p" "/home/${app}/current/artisan" "$@"
}

# ── ALIAS ─────────────────────────────────────────────────────

alias_add() {
    local app="${1:-}" dom="${2:-}"
    [[ -z "$app" || -z "$dom" ]] && { error "Usage: cipi alias add <app> <domain>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    validate_domain "$dom" || { error "Invalid domain"; exit 1; }
    local tmp; tmp=$(mktemp)
    jq --arg a "$app" --arg d "$dom" '.[$a].aliases+=[$d]|.[$a].aliases|=unique' "${CIPI_CONFIG}/apps.json">"$tmp"
    mv "$tmp" "${CIPI_CONFIG}/apps.json"; chmod 600 "${CIPI_CONFIG}/apps.json"
    _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)"; reload_nginx
    log_action "ALIAS ADDED: $dom → $app"
    success "'${dom}' added to '${app}'"
    info "Run: cipi ssl install ${app}  (to update certificate)"
}

alias_remove() {
    local app="${1:-}" dom="${2:-}"
    [[ -z "$app" || -z "$dom" ]] && { error "Usage: cipi alias remove <app> <domain>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    local tmp; tmp=$(mktemp)
    jq --arg a "$app" --arg d "$dom" '.[$a].aliases-=[$d]' "${CIPI_CONFIG}/apps.json">"$tmp"
    mv "$tmp" "${CIPI_CONFIG}/apps.json"; chmod 600 "${CIPI_CONFIG}/apps.json"
    _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)"; reload_nginx
    success "'${dom}' removed from '${app}'"
}

alias_list() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi alias list <app>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    echo -e "\n${BOLD}Domains for '${app}'${NC}"
    echo -e "  Primary: ${CYAN}$(app_get "$app" domain)${NC}"
    jq -r --arg a "$app" '.[$a].aliases[]?//empty' "${CIPI_CONFIG}/apps.json" | while read -r a; do
        echo -e "  Alias:   ${CYAN}${a}${NC}"
    done; echo ""
}

# ── HELPERS ───────────────────────────────────────────────────

_create_fpm_pool() {
    local app="$1" v="$2"
    cat > "/etc/php/${v}/fpm/pool.d/${app}.conf" <<EOF
[${app}]
user = ${app}
group = ${app}
listen = /run/php/${app}.sock
listen.owner = ${app}
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
pm.max_requests = 500
request_terminate_timeout = 300
php_admin_value[open_basedir] = /home/${app}/:/tmp/:/proc/
php_admin_value[upload_max_filesize] = 256M
php_admin_value[post_max_size] = 256M
php_admin_value[memory_limit] = 256M
php_admin_value[max_execution_time] = 300
php_admin_value[error_log] = /home/${app}/logs/php-fpm-error.log
php_admin_flag[log_errors] = on
EOF
}

_create_nginx_vhost() {
    local app="$1" domain="$2" v="$3"
    local names="$domain"
    local aliases
    if [[ $# -ge 4 ]]; then
        aliases="${4:-}"
    else
        aliases=$(jq -r --arg a "$app" '.[$a].aliases[]?//empty' "${CIPI_CONFIG}/apps.json" 2>/dev/null || true)
    fi
    [[ -n "$aliases" ]] && names="$domain $aliases"
    cat > "/etc/nginx/sites-available/${app}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${names};
    root /home/${app}/current/public;
    index index.php;
    access_log /home/${app}/logs/nginx-access.log;
    error_log /home/${app}/logs/nginx-error.log;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    client_max_body_size 256M;
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php$ {
        fastcgi_pass unix:/run/php/${app}.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
        fastcgi_read_timeout 300;
    }
    location ~ /\.(?!well-known) { deny all; }
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }
    error_page 404 /index.php;
}
EOF
}

_create_supervisor_worker() {
    local app="$1" v="$2" queue="${3:-default}" procs="${4:-1}" tries="${5:-3}" timeout="${6:-3600}"
    cat >> "/etc/supervisor/conf.d/${app}.conf" <<EOF
[program:${app}-worker-${queue}]
process_name=%(program_name)s_%(process_num)02d
command=/usr/bin/php${v} /home/${app}/current/artisan queue:work database --sleep=3 --tries=${tries} --max-time=${timeout} --queue=${queue}
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=${app}
numprocs=${procs}
redirect_stderr=true
stdout_logfile=/home/${app}/logs/worker-${queue}.log
stdout_logfile_maxbytes=10MB
stopwaitsecs=${timeout}
EOF
}

_create_deployer_config() {
    local an="$1" repo="$2" branch="$3" v="$4"
    local dh="/home/${an}"
    cat > "${dh}/.deployer/deploy.php" <<'PHPTOP'
<?php
namespace Deployer;
require 'recipe/laravel.php';

PHPTOP
    cat >> "${dh}/.deployer/deploy.php" <<PHP
set('application', '${an}');
set('repository', '${repo}');
set('branch', '${branch}');
set('deploy_path', '${dh}');
set('keep_releases', 5);
set('git_ssh_command', 'ssh -i ${dh}/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new');
set('bin/php', '/usr/bin/php${v}');
set('writable_mode', 'chmod');

add('shared_files', ['.env']);
add('shared_dirs', ['storage']);
add('writable_dirs', [
    'bootstrap/cache', 'storage', 'storage/app', 'storage/app/public',
    'storage/framework', 'storage/framework/cache', 'storage/framework/cache/data',
    'storage/framework/sessions', 'storage/framework/views', 'storage/logs',
]);

host('localhost')
    ->set('remote_user', '${an}')
    ->set('deploy_path', '${dh}');

after('deploy:vendors', 'artisan:storage:link');
after('deploy:vendors', 'artisan:migrate');
after('deploy:vendors', 'artisan:optimize');
after('deploy:symlink', 'artisan:queue:restart');
after('deploy:symlink', 'workers:restart');

task('workers:restart', function () {
    run('sudo /usr/local/bin/cipi-worker restart ${an}');
});
PHP
    chown -R "${an}:${an}" "${dh}/.deployer"
}

# ── ROUTERS ───────────────────────────────────────────────────

app_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        create)  app_create "$@" ;;
        list|ls) app_list ;;
        show)    app_show "$@" ;;
        edit)    app_edit "$@" ;;
        delete)  app_delete "$@" ;;
        env)     app_env "$@" ;;
        logs)    app_logs "$@" ;;
        tinker)  app_tinker "$@" ;;
        artisan) app_artisan "$@" ;;
        *) error "Unknown: $sub"; echo "Use: create list show edit delete env logs tinker artisan"; exit 1 ;;
    esac
}

alias_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        add)    alias_add "$@" ;;
        remove) alias_remove "$@" ;;
        list)   alias_list "$@" ;;
        *) error "Unknown: $sub"; echo "Use: add remove list"; exit 1 ;;
    esac
}
