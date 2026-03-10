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
    [[ -z "${ARG_branch:-}" ]] && read_input "Branch" "$branch" branch
    [[ -z "${ARG_php:-}" ]]   && read_input "PHP version" "$php_ver" php_ver

    # Validate
    validate_username "$app_user"  || { error "Invalid username '${app_user}'"; exit 1; }
    validate_domain "$domain"      || { error "Invalid domain '${domain}'"; exit 1; }
    validate_php_version "$php_ver" || { error "Invalid PHP version. Use: 7.4 8.0 8.1 8.2 8.3 8.4 8.5"; exit 1; }
    php_is_installed "$php_ver"    || { error "PHP $php_ver not installed. Run: cipi php install $php_ver"; exit 1; }
    app_exists "$app_user"         && { error "App '${app_user}' already exists"; exit 1; }
    id "$app_user" &>/dev/null     && { error "User '${app_user}' already exists"; exit 1; }
    domain_is_used_by_other_app "$domain" && { error "Domain '${domain}' is already used by app '${DOMAIN_USED_BY_APP}'"; exit 1; }

    echo ""; info "Creating '${app_user}'..."; echo ""

    local user_pass db_pass webhook_token app_key home
    user_pass=$(generate_password 40)
    db_pass=$(generate_password 40)
    webhook_token=$(generate_token)
    app_key=$(generate_app_key)
    home="/home/${app_user}"

    # 1. Linux user
    step "Creating user..."
    useradd -m -s /bin/bash -G www-data,cipi-apps "$app_user"
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
    ssh-keyscan -H localhost 127.0.0.1 github.com gitlab.com 2>/dev/null >> "${home}/.ssh/known_hosts"
    chown "${app_user}:${app_user}" "${home}/.ssh/known_hosts"
    chmod 600 "${home}/.ssh/known_hosts"
    success "Deploy key"

    # 3b. Git provider integration (auto-add deploy key + webhook)
    source "${CIPI_LIB}/git.sh"
    git_setup_repo "$app_user" "$repository" "$domain" "$webhook_token" "$deploy_key"

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
    # Save git integration IDs (if provider was configured)
    if [[ -n "${GIT_PROVIDER:-}" ]]; then
        git_save_app_data "$app_user" "$GIT_PROVIDER" "${GIT_DEPLOY_KEY_ID:-}" "${GIT_WEBHOOK_ID:-}"
    fi
    log_action "APP CREATED: $app_user domain=$domain php=$php_ver"

    # Email notification
    cipi_notify \
        "Cipi app created: ${app_user} on $(hostname)" \
        "A new app was created.\n\nServer: $(hostname)\nApp: ${app_user}\nDomain: ${domain}\nPHP: ${php_ver}\nBranch: ${branch}\nRepository: ${repository}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')"

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

    # 12. Sudoers (worker + deploy + ssl, scoped to own app)
    step "Permissions..."
    cat > "/etc/sudoers.d/cipi-${app_user}" <<SUDO
${app_user} ALL=(root) NOPASSWD: /usr/local/bin/cipi-worker restart ${app_user}
${app_user} ALL=(root) NOPASSWD: /usr/local/bin/cipi-worker stop ${app_user}
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
    if [[ -n "${GIT_PROVIDER:-}" && -n "${GIT_DEPLOY_KEY_ID:-}" && -n "${GIT_WEBHOOK_ID:-}" ]]; then
        echo -e "  ${BOLD}Git${NC}         ${GREEN}${GIT_PROVIDER} auto-configured ✓${NC}"
        echo -e "  ${BOLD}Webhook${NC}     ${CYAN}https://${domain}/cipi/webhook${NC}"
    else
        echo -e "  ${BOLD}Deploy Key${NC}  (add to your Git provider)"
        echo -e "  ${CYAN}${deploy_key}${NC}"
        echo ""
        echo -e "  ${BOLD}Webhook${NC}     ${CYAN}https://${domain}/cipi/webhook${NC}"
        echo -e "  ${BOLD}Token${NC}       ${CYAN}${webhook_token}${NC}"
        if [[ -z "${GIT_PROVIDER:-}" ]]; then
            echo ""
            echo -e "  ${DIM}Tip: cipi git github-token <PAT> to auto-configure next time${NC}"
        fi
    fi
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
    local _aj; _aj=$(vault_read apps.json)
    if [[ $(echo "$_aj" | jq 'length') -eq 0 ]]; then
        info "No apps. Create one: cipi app create"; return
    fi
    printf "\n${BOLD}%-14s %-28s %-6s %s${NC}\n" "APP" "DOMAIN" "PHP" "CREATED"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$_aj" | jq -r 'to_entries[]|"\(.key)\t\(.value.domain)\t\(.value.php)\t\(.value.created_at)"' \
        | while IFS=$'\t' read -r a d p c; do
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
    aliases=$(vault_read apps.json | jq -r --arg a "$app" '.[$a].aliases//[]|join(", ")')
    [[ -z "$aliases" ]] && aliases="none"

    echo -e "\n${BOLD}${app}${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-14s ${CYAN}%s${NC}\n" "Domain" "$d"
    printf "  %-14s ${CYAN}%s${NC}\n" "Aliases" "$aliases"
    printf "  %-14s ${CYAN}%s${NC}\n" "Repository" "$repo"
    printf "  %-14s ${CYAN}%s${NC}\n" "Branch" "$b"
    printf "  %-14s ${CYAN}%s${NC}\n" "PHP" "$p"
    printf "  %-14s ${CYAN}%s${NC}\n" "Created" "$ca"
    local git_prov; git_prov=$(app_get "$app" git_provider)
    if [[ -n "$git_prov" ]]; then
        local git_dkid; git_dkid=$(app_get "$app" git_deploy_key_id)
        local git_whid; git_whid=$(app_get "$app" git_webhook_id)
        printf "  %-14s ${GREEN}%s${NC} (key:%s hook:%s)\n" "Git" "$git_prov" "${git_dkid:-manual}" "${git_whid:-manual}"
    fi

    echo -e "\n  ${BOLD}Webhook${NC}  ${CYAN}https://${d}/cipi/webhook${NC}"

    if [[ -f "/home/${app}/.ssh/id_ed25519.pub" ]]; then
        echo -e "\n  ${BOLD}Deploy Key${NC}\n  ${CYAN}$(cat "/home/${app}/.ssh/id_ed25519.pub")${NC}"
    fi
    if [[ -L "/home/${app}/current" ]]; then
        echo -e "\n  ${BOLD}Release${NC}  ${CYAN}$(readlink -f "/home/${app}/current" | xargs basename)${NC}"
    fi
    echo -e "\n  ${BOLD}Workers${NC}"
    local workers
    workers=$(supervisorctl status 2>/dev/null | grep "^${app}-worker-" || true)
    if [[ -n "$workers" ]]; then
        echo "$workers" | sed 's/^/  /'
    else
        echo "  none"
    fi
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
        sed -i "s|/usr/bin/php[0-9]\.[0-9]|/usr/bin/php${np}|g" "/etc/supervisor/conf.d/${app}.conf" 2>/dev/null
        reload_supervisor
        crontab -u "$app" -l 2>/dev/null | sed "s|php${cur_php}|php${np}|g" | crontab -u "$app" -
        sed -i "s|php${cur_php}|php${np}|g" "/home/${app}/.bashrc" "/home/${app}/.deployer/deploy.php" 2>/dev/null
        sed -i "s|^CIPI_PHP_VERSION=.*|CIPI_PHP_VERSION=${np}|" "/home/${app}/shared/.env"
        app_set "$app" php "$np"; success "PHP → $np"; changed=true
    fi
    if [[ -n "${ARG_branch:-}" ]]; then
        app_set "$app" branch "${ARG_branch}"
        local safe_branch; safe_branch=$(printf '%s' "${ARG_branch}" | sed 's/[&|\\\/]/\\&/g')
        sed -i "s|set('branch', '.*')|set('branch', '${safe_branch}')|" "/home/${app}/.deployer/deploy.php"
        success "Branch → ${ARG_branch}"; changed=true
    fi
    if [[ -n "${ARG_repository:-}" ]]; then
        local old_repo; old_repo=$(app_get "$app" repository)
        app_set "$app" repository "${ARG_repository}"
        local safe_repo; safe_repo=$(printf '%s' "${ARG_repository}" | sed 's/[&|\\\/]/\\&/g')
        sed -i "s|set('repository', '.*')|set('repository', '${safe_repo}')|" "/home/${app}/.deployer/deploy.php"

        # Migrate git provider integration
        source "${CIPI_LIB}/git.sh"
        git_cleanup_repo "$app" "$old_repo"
        git_clear_app_data "$app"
        local pub_key=""
        [[ -f "/home/${app}/.ssh/id_ed25519.pub" ]] && pub_key=$(cat "/home/${app}/.ssh/id_ed25519.pub")
        local wt; wt=$(app_get "$app" webhook_token)
        local d; d=$(app_get "$app" domain)
        if [[ -n "$pub_key" ]]; then
            git_setup_repo "$app" "${ARG_repository}" "$d" "$wt" "$pub_key"
            if [[ -n "${GIT_PROVIDER:-}" ]]; then
                git_save_app_data "$app" "$GIT_PROVIDER" "${GIT_DEPLOY_KEY_ID:-}" "${GIT_WEBHOOK_ID:-}"
            fi
        fi

        success "Repository updated"; changed=true
    fi
    [[ "$changed" == false ]] && info "Nothing changed. Use --php, --branch, or --repository"
    if [[ "$changed" == true ]]; then
        log_action "APP EDITED: $app $*"

        # Email notification
        local edit_details=""
        [[ -n "${ARG_php:-}" ]] && edit_details="${edit_details}PHP: ${cur_php} → ${ARG_php}\n"
        [[ -n "${ARG_branch:-}" ]] && edit_details="${edit_details}Branch: ${ARG_branch}\n"
        [[ -n "${ARG_repository:-}" ]] && edit_details="${edit_details}Repository: ${ARG_repository}\n"
        cipi_notify \
            "Cipi app modified: ${app} on $(hostname)" \
            "An app was modified.\n\nServer: $(hostname)\nApp: ${app}\nDomain: $(app_get "$app" domain)\n\nChanges:\n${edit_details}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    fi
}

# ── DELETE ────────────────────────────────────────────────────

app_delete() {
    local app="${1:-}"; shift || true
    [[ -z "$app" ]] && { error "Usage: cipi app delete <app> [--force]"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    parse_args "$@"
    local d; d=$(app_get "$app" domain); local p; p=$(app_get "$app" php)

    if [[ "${ARG_force:-}" != "true" ]]; then
        echo ""; warn "Will permanently delete: user, home, database, vhost, workers, SSL"
        confirm "Delete '${app}'?" || { info "Cancelled"; return; }
    fi

    # Git provider cleanup (remove deploy key + webhook from repo)
    local repo; repo=$(app_get "$app" repository)
    if [[ -n "$repo" ]]; then
        source "${CIPI_LIB}/git.sh"
        git_cleanup_repo "$app" "$repo"
    fi

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

    # Email notification
    cipi_notify \
        "Cipi app deleted: ${app} on $(hostname)" \
        "An app was deleted.\n\nServer: $(hostname)\nApp: ${app}\nDomain: ${d}\nPHP: ${p}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')"

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
    [[ -z "$app" ]] && { error "Usage: cipi app logs <app> [--type=nginx|php|worker|deploy|laravel|all]"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    parse_args "$@"
    local laravel_dir="/home/${app}/shared/storage/logs"
    case "${ARG_type:-all}" in
        nginx)   tail -f "/home/${app}/logs/nginx-"*.log ;;
        php)     tail -f "/home/${app}/logs/php-fpm-"*.log ;;
        worker)  tail -f "/home/${app}/logs/worker-"*.log ;;
        deploy)  tail -f "/home/${app}/logs/deploy.log" ;;
        laravel) tail -f "${laravel_dir}/"*.log ;;
        all)     tail -f "/home/${app}/logs/"*.log "${laravel_dir}/"*.log ;;
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
    local primary; primary=$(app_get "$app" domain)
    [[ "$dom" == "$primary" ]] && { error "'${dom}' is already the primary domain"; exit 1; }
    domain_is_used_by_other_app "$dom" "$app" && { error "Domain '${dom}' is already used by app '${DOMAIN_USED_BY_APP}'"; exit 1; }
    vault_read apps.json | jq --arg a "$app" --arg d "$dom" '.[$a].aliases+=[$d]|.[$a].aliases|=unique' | vault_write apps.json
    ensure_apps_json_api_access
    _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)"; reload_nginx
    log_action "ALIAS ADDED: $dom → $app"
    success "'${dom}' added to '${app}'"
    info "Run: cipi ssl install ${app}  (to update certificate)"
}

alias_remove() {
    local app="${1:-}" dom="${2:-}"
    [[ -z "$app" || -z "$dom" ]] && { error "Usage: cipi alias remove <app> <domain>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    vault_read apps.json | jq --arg a "$app" --arg d "$dom" '.[$a].aliases-=[$d]' | vault_write apps.json
    ensure_apps_json_api_access
    _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)"; reload_nginx
    success "'${dom}' removed from '${app}'"
}

alias_list() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi alias list <app>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    echo -e "\n${BOLD}Domains for '${app}'${NC}"
    echo -e "  Primary: ${CYAN}$(app_get "$app" domain)${NC}"
    vault_read apps.json | jq -r --arg a "$app" '.[$a].aliases // [] | .[]' | while read -r a; do
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
    local names aliases_raw
    if [[ $# -ge 4 ]]; then
        aliases_raw="${4:-}"
    else
        # Exclude primary domain from aliases to avoid duplicates
        aliases_raw=$(vault_read apps.json | jq -r --arg a "$app" --arg d "$domain" '.[$a].aliases // [] | map(select(. != $d)) | .[]' 2>/dev/null || true)
    fi
    # Deduplicate: domain + aliases, preserving order, avoiding Nginx "conflicting server name" warnings
    names=$(echo -e "${domain}\n${aliases_raw}" | grep -v '^[[:space:]]*$' | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ $//')
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
    ->set('deploy_path', '${dh}')
    ->set('ssh_arguments', ['-o StrictHostKeyChecking=accept-new', '-i ${dh}/.ssh/id_ed25519']);

after('deploy:vendors', 'artisan:storage:link');
after('deploy:vendors', 'artisan:migrate');
after('deploy:vendors', 'artisan:optimize');
before('deploy:symlink', 'workers:stop');
after('deploy:symlink', 'artisan:queue:restart');
after('deploy:symlink', 'workers:restart');

task('workers:stop', function () {
    run('sudo /usr/local/bin/cipi-worker stop ${an}');
});

task('workers:restart', function () {
    run('sudo /usr/local/bin/cipi-worker restart ${an}');
});
PHP
    chown -R "${an}:${an}" "${dh}/.deployer"
}

# ── AUTH ──────────────────────────────────────────────────────

auth_create() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi auth create <app>"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    local auth_file="/home/${app}/shared/auth.json"
    if [[ -f "$auth_file" ]]; then
        warn "auth.json already exists for '${app}'"
        confirm "Overwrite?" || { info "Cancelled"; return; }
    fi
    cat > "$auth_file" <<JSON
{
    "users": []
}
JSON
    chown "${app}:${app}" "$auth_file"
    chmod 640 "$auth_file"

    if grep -q "shared_files" "/home/${app}/.deployer/deploy.php" 2>/dev/null; then
        if ! grep -q "auth.json" "/home/${app}/.deployer/deploy.php" 2>/dev/null; then
            sed -i "s|add('shared_files', \['.env'\]);|add('shared_files', ['.env', 'auth.json']);|" "/home/${app}/.deployer/deploy.php"
            info "auth.json added to Deployer shared_files"
        fi
    fi

    log_action "AUTH CREATED: $app"
    success "auth.json created at ${auth_file}"
    info "Edit it with: cipi auth edit ${app}"
}

auth_edit() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi auth edit <app>"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    local auth_file="/home/${app}/shared/auth.json"
    [[ ! -f "$auth_file" ]] && { error "auth.json not found. Run: cipi auth create ${app}"; exit 1; }
    ${EDITOR:-nano} "$auth_file"
    if jq empty "$auth_file" 2>/dev/null; then
        chown "${app}:${app}" "$auth_file"; chmod 640 "$auth_file"
        log_action "AUTH EDITED: $app"
        success "auth.json updated"
    else
        error "Invalid JSON — file saved but may be malformed. Fix it manually: ${auth_file}"
    fi
}

auth_show() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi auth show <app>"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    local auth_file="/home/${app}/shared/auth.json"
    [[ ! -f "$auth_file" ]] && { error "auth.json not found. Run: cipi auth create ${app}"; exit 1; }
    echo -e "\n${BOLD}auth.json — ${app}${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    jq . "$auth_file" 2>/dev/null || cat "$auth_file"
    echo ""
}

auth_delete() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi auth delete <app>"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    local auth_file="/home/${app}/shared/auth.json"
    [[ ! -f "$auth_file" ]] && { error "auth.json not found for '${app}'"; exit 1; }
    confirm "Delete auth.json for '${app}'?" || { info "Cancelled"; return; }
    rm -f "$auth_file"

    if grep -q "auth.json" "/home/${app}/.deployer/deploy.php" 2>/dev/null; then
        sed -i "s|add('shared_files', \['.env', 'auth.json'\]);|add('shared_files', ['.env']);|" "/home/${app}/.deployer/deploy.php"
        info "auth.json removed from Deployer shared_files"
    fi

    log_action "AUTH DELETED: $app"
    success "auth.json deleted for '${app}'"
}

# ── RESET PASSWORDS ───────────────────────────────────────────

app_reset_password() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi app reset-password <app>"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    id "$app" &>/dev/null || { error "System user '$app' not found"; exit 1; }

    local new_pass
    new_pass=$(generate_password 40)
    echo "${app}:${new_pass}" | chpasswd

    log_action "APP SSH PASSWORD RESET: $app"

    cipi_notify \
        "Cipi app SSH password reset: ${app} on $(hostname)" \
        "The SSH password for app '${app}' was regenerated.\n\nServer: $(hostname)\nApp: ${app}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')"

    echo ""
    echo -e "${GREEN}✓${NC} New SSH password for '${app}': ${CYAN}${new_pass}${NC}"
    echo -e "${YELLOW}${BOLD}⚠ SAVE THIS PASSWORD — shown only once${NC}"
    echo ""
}

app_reset_db_password() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi app reset-db-password <app>"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }

    local new_pass dbr
    new_pass=$(generate_password 40)
    dbr=$(get_db_root_password)

    mariadb -u root -p"${dbr}" <<SQL
ALTER USER '${app}'@'localhost' IDENTIFIED BY '${new_pass}';
ALTER USER '${app}'@'127.0.0.1' IDENTIFIED BY '${new_pass}';
FLUSH PRIVILEGES;
SQL

    # Update .env if it exists
    local env_file="/home/${app}/shared/.env"
    if [[ -f "$env_file" ]]; then
        sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${new_pass}|" "$env_file"
        chown "${app}:${app}" "$env_file"
        chmod 640 "$env_file"
        info ".env updated with new DB password"
    else
        warn "Update DB_PASSWORD in your .env manually!"
    fi

    log_action "APP DB PASSWORD RESET: $app"

    cipi_notify \
        "Cipi app DB password reset: ${app} on $(hostname)" \
        "The database password for app '${app}' was regenerated.\n\nServer: $(hostname)\nApp: ${app}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')"

    echo ""
    echo -e "${GREEN}✓${NC} New DB password for '${app}': ${CYAN}${new_pass}${NC}"
    echo -e "${YELLOW}${BOLD}⚠ SAVE THIS PASSWORD — shown only once${NC}"
    echo ""
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
        reset-password)    app_reset_password "$@" ;;
        reset-db-password) app_reset_db_password "$@" ;;
        *) error "Unknown: $sub"; echo "Use: create list show edit delete env logs tinker artisan reset-password reset-db-password"; exit 1 ;;
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

auth_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        create) auth_create "$@" ;;
        edit)   auth_edit "$@" ;;
        show)   auth_show "$@" ;;
        delete) auth_delete "$@" ;;
        *) error "Unknown: $sub"; echo "Use: create edit show delete"; exit 1 ;;
    esac
}
