#!/bin/bash
#############################################
# Cipi — Application Management
#############################################

# ── CREATE ────────────────────────────────────────────────────

app_create() {
    parse_args "$@"
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/db.sh"
    local app_user="${ARG_user:-}" domain="${ARG_domain:-}" repository="${ARG_repository:-}"
    local branch="${ARG_branch:-main}" php_ver="${ARG_php:-8.5}"
    local is_custom="${ARG_custom:-false}"
    local db_engine="${ARG_engine:-}"
    local octane_server="" octane_port=""

    # App type: laravel (default) or custom
    local app_type="laravel"
    [[ "$is_custom" == "true" ]] && app_type="custom"

    # Optional Laravel Octane (FrankenPHP) — parallel to PHP-FPM apps
    if [[ -n "${ARG_octane+x}" ]]; then
        octane_server=$(_normalize_octane_arg "${ARG_octane}") || {
            error "Invalid --octane value. Use: frankenphp (or --octane with no value)"
            exit 1
        }
    fi
    if [[ -n "$octane_server" && "$app_type" == "custom" ]]; then
        error "Octane is only available for Laravel apps (not --custom)"
        exit 1
    fi

    # Interactive prompts for missing fields
    [[ -z "$app_user" ]]    && read_input "App username (lowercase, min 3 chars)" "" app_user
    [[ -z "$domain" ]]      && read_input "Primary domain" "" domain
    if [[ "$app_type" == "custom" ]]; then
        if [[ -z "$repository" && "${ARG_repository+x}" != x ]]; then
            read_input "Git — leave empty to use SFTP only (no repository)" "" repository
        fi
    else
        [[ -z "$repository" ]] && read_input "Git repository URL (SSH)" "" repository
    fi
    [[ "$app_type" == "laravel" && -z "$repository" ]] && { error "Git repository is required for Laravel apps"; exit 1; }
    if [[ "$app_type" == "custom" && -z "$repository" ]]; then
        branch=""
    elif [[ -z "${ARG_branch:-}" ]]; then
        read_input "Branch" "$branch" branch
    fi
    [[ -z "${ARG_php:-}" ]] && read_input "PHP version" "$php_ver" php_ver

    # Database engine (Laravel only)
    if [[ "$app_type" == "laravel" ]]; then
        db_ensure_engine_state
        local default_engine
        default_engine=$(db_get_default_engine)
        if [[ -z "$db_engine" ]]; then
            local -a _eng_opts=()
            db_engine_is_installed mariadb && _eng_opts+=("mariadb")
            db_engine_is_installed pgsql && _eng_opts+=("pgsql")
            local engine_opts
            engine_opts=$(IFS='|'; echo "${_eng_opts[*]}")
            [[ -z "$engine_opts" ]] && { error "No database engine installed"; exit 1; }
            read_input "Database engine (${engine_opts})" "$default_engine" db_engine
        fi
        [[ -z "$db_engine" ]] && db_engine="$default_engine"
        db_engine=$(db_normalize_engine "$db_engine") || { error "Invalid engine. Use: mariadb pgsql"; exit 1; }
        db_require_engine "$db_engine" >/dev/null || exit 1
    else
        db_engine=""
    fi

    # Custom app: docroot only (Nginx always uses index.php)
    local docroot=""
    if [[ "$app_type" == "custom" ]]; then
        docroot="${ARG_docroot:-}"
        if [[ -z "$docroot" ]]; then
            echo -e "  Document root under htdocs (default /): e.g. ${CYAN}/${NC}, ${CYAN}www${NC}, ${CYAN}dist${NC}, ${CYAN}public${NC}"
            read_input "Docroot" "/" docroot
        fi
        [[ "$docroot" == "/" || "$docroot" == "." ]] && docroot=""
    fi

    # Validate
    validate_username "$app_user"  || { error "Invalid username '${app_user}'"; exit 1; }
    validate_domain_or_wildcard "$domain" || { error "Invalid domain '${domain}'"; exit 1; }
    validate_php_version "$php_ver" || { error "Invalid PHP version. Use: 8.3 8.4 8.5"; exit 1; }
    [[ -n "$repository" ]] && { validate_git_repository "$repository" || { error "Invalid repository URL '${repository}'"; exit 1; }; }
    [[ -n "$branch" ]]     && { validate_git_branch "$branch"         || { error "Invalid branch name '${branch}'"; exit 1; }; }
    php_is_installed "$php_ver"    || { error "PHP $php_ver not installed. Run: cipi php install $php_ver"; exit 1; }
    app_exists "$app_user"         && { error "App '${app_user}' already exists"; exit 1; }
    id "$app_user" &>/dev/null     && { error "User '${app_user}' already exists"; exit 1; }
    domain_is_used_by_other_app "$domain" && { error "Domain '${domain}' is already used by app '${DOMAIN_USED_BY_APP}'"; exit 1; }

    if [[ -n "$octane_server" ]]; then
        octane_port=$(_octane_allocate_port) || {
            error "No free Octane port available in range 8100–8999"
            exit 1
        }
    fi

    echo ""; info "Creating '${app_user}' (${app_type}${octane_server:+, octane=${octane_server}})..."; echo ""

    local user_pass db_pass webhook_token app_key home url_host
    # A wildcard primary is a valid nginx server_name but not a hostname, so
    # every URL built for the app (APP_URL, webhook) names a concrete tenant.
    url_host=$(domain_url_host "$domain")
    user_pass=$(generate_password 40)
    db_pass=""
    if [[ "$app_type" == "laravel" ]]; then
        db_pass=$(generate_password 40)
        webhook_token=$(generate_token)
        app_key=$(generate_app_key)
    else
        webhook_token=""
        app_key=""
    fi
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
    if [[ "$app_type" == "custom" ]]; then
        mkdir -p "${home}"/{shared,logs,.ssh,.deployer}
        if [[ -z "$repository" ]]; then
            mkdir -p "${home}/htdocs"
            cat > "${home}/htdocs/index.html" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="robots" content="noindex, nofollow">
<title>${domain}</title>
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
  .emoji-wrap {
    font-size: 2.5rem;
    line-height: 1;
    margin-bottom: 1rem;
  }
  .host-text {
    font-size: 1rem;
    font-weight: 300;
    letter-spacing: 4px;
    color: #666;
    margin-top: -0.25rem;
  }
  .sub-text {
    font-size: 0.8125rem;
    font-weight: 400;
    color: #888;
    margin-top: 0.65rem;
    letter-spacing: 0.02em;
  }
  .status-text {
    font-size: 0.75rem;
    font-weight: 400;
    color: #999;
    margin-top: 0.45rem;
    word-break: break-all;
  }
  @media (max-width: 600px) {
    .emoji-wrap { font-size: 2rem; }
    .host-text { font-size: 0.75rem; letter-spacing: 3px; }
  }
</style>
</head>
<body>
<div class="container">
  <div class="emoji-wrap" aria-hidden="true">🚀</div>
  <div class="host-text" id="host-label">${domain}</div>
  <div class="sub-text">is currently being deployed.</div>
  <div class="status-text">Please check back soon.</div>
</div>
<script>
  var h = window.location.hostname;
  document.getElementById('host-label').textContent = h;
  document.title = h + ' · is currently being deployed.';
</script>
</body>
</html>
HTML
            chown "${app_user}:${app_user}" "${home}/htdocs/index.html"
        fi
    elif [[ "$app_type" == "laravel" ]]; then
        mkdir -p "${home}"/{shared/storage/{app/public,framework/{cache/data,sessions,views},logs},logs,.ssh,.deployer}
    fi
    if [[ "$app_type" == "custom" ]]; then
        cat > "${home}/.bashrc" <<BASH
export PATH="/usr/local/bin:\$PATH"
alias ll='ls -al'
alias php='/usr/bin/php${php_ver}'
alias composer='/usr/bin/php${php_ver} /usr/local/bin/composer'
alias deploy='/usr/bin/php${php_ver} /usr/local/bin/dep deploy -f ${home}/.deployer/deploy.php'
PS1='\[\033[0;32m\]\u\[\033[0m\]@\h:\[\033[0;34m\]\w\[\033[0m\]\$ '
BASH
    else
        cat > "${home}/.bashrc" <<BASH
export PATH="/usr/local/bin:\$PATH"
alias ll='ls -al'
alias php='/usr/bin/php${php_ver}'
alias artisan='php ${home}/current/artisan'
alias composer='/usr/bin/php${php_ver} /usr/local/bin/composer'
alias tinker='artisan tinker'
alias deploy='/usr/bin/php${php_ver} /usr/local/bin/dep deploy -f ${home}/.deployer/deploy.php'
PS1='\[\033[0;32m\]\u\[\033[0m\]@\h:\[\033[0;34m\]\w\[\033[0m\]\$ '
BASH
    fi
    chown -R "${app_user}:${app_user}" "$home"
    ensure_app_logs_permissions "$app_user"
    success "Directories"

    # 3. SSH deploy key (for GitHub) + authorized_keys (for Deployer localhost SSH)
    # ~/.ssh must be 700: umask 002 makes mkdir create 775, and sshd StrictModes
    # then rejects pubkey auth ("bad ownership or modes") → password prompt on deploy.
    step "Deploy key..."
    chmod 700 "${home}/.ssh"
    sudo -u "$app_user" ssh-keygen -t ed25519 -C "${app_user}@cipi" -f "${home}/.ssh/id_ed25519" -N "" -q
    local deploy_key; deploy_key=$(cat "${home}/.ssh/id_ed25519.pub")
    echo "$deploy_key" >> "${home}/.ssh/authorized_keys"
    chown "${app_user}:${app_user}" "${home}/.ssh/authorized_keys"
    chmod 600 "${home}/.ssh/authorized_keys"
    ssh-keyscan -H localhost 127.0.0.1 github.com gitlab.com 2>/dev/null >> "${home}/.ssh/known_hosts"
    chown "${app_user}:${app_user}" "${home}/.ssh/known_hosts"
    chmod 600 "${home}/.ssh/known_hosts"
    chmod 700 "${home}/.ssh"
    success "Deploy key"

    # 3b. Git provider integration (auto-add deploy key; webhook only for Laravel)
    source "${CIPI_LIB}/git.sh"
    if [[ "$app_type" == "laravel" ]]; then
        git_setup_repo "$app_user" "$repository" "$url_host" "$webhook_token" "$deploy_key"
    else
        git_setup_repo "$app_user" "$repository" "$url_host" "" "$deploy_key" "skip_webhook"
    fi

    # 4. Database (Laravel only)
    if [[ "$app_type" == "laravel" ]]; then
        step "Database ($(db_engine_label "$db_engine"))..."
        db_create_database "$db_engine" "$app_user" "$app_user" "$db_pass" \
            || { error "Database create failed"; exit 1; }
        success "Database ($(db_engine_label "$db_engine"))"
    fi

    # 5. Config: .env (Laravel only)
    if [[ "$app_type" == "laravel" ]]; then
        step ".env..."
        local db_env
        db_env=$(db_laravel_env_block "$db_engine" "$app_user" "$app_user" "$db_pass")
        cat > "${home}/shared/.env" <<ENV
APP_NAME="${app_user}"
APP_ENV=production
APP_KEY=${app_key}
APP_DEBUG=false
APP_URL=https://${url_host}

LOG_CHANNEL=daily
LOG_LEVEL=error

${db_env}

BROADCAST_CONNECTION=log
CACHE_STORE=database
SESSION_DRIVER=database
QUEUE_CONNECTION=database

MAIL_MAILER=log

CIPI_WEBHOOK_TOKEN=${webhook_token}
CIPI_APP_USER=${app_user}
CIPI_PHP_VERSION=${php_ver}
ENV
        if [[ -n "$octane_server" ]]; then
            cat >> "${home}/shared/.env" <<ENV

OCTANE_SERVER=${octane_server}
OCTANE_HTTPS=true
ENV
        fi
        chown "${app_user}:${app_user}" "${home}/shared/.env"
        chmod 640 "${home}/shared/.env"
        success ".env with DB + webhook"
    fi

    # 6. PHP-FPM pool (Laravel and custom) — skipped for Octane apps
    if [[ -n "$octane_server" ]]; then
        step "PHP-FPM pool..."
        success "Skipped (Octane)"
    elif [[ "$app_type" == "laravel" || "$app_type" == "custom" ]]; then
        step "PHP-FPM pool..."
        _create_fpm_pool "$app_user" "$php_ver"
        reload_php_fpm "$php_ver"
        success "PHP-FPM ${php_ver}"
    fi

    # 7. Save config early (needed before nginx so Octane vhost reads octane_port)
    if [[ "$app_type" == "custom" ]]; then
        app_save "$app_user" "$(cat <<JSON
{
    "user": "${app_user}",
    "domain": "${domain}",
    "aliases": [],
    "repository": "${repository}",
    "branch": "${branch}",
    "php": "${php_ver}",
    "custom": true,
    "docroot": "${docroot}",
    "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
JSON
)"
    elif [[ -n "$octane_server" ]]; then
        app_save "$app_user" "$(cat <<JSON
{
    "user": "${app_user}",
    "domain": "${domain}",
    "aliases": [],
    "repository": "${repository}",
    "branch": "${branch}",
    "php": "${php_ver}",
    "engine": "${db_engine}",
    "octane": "${octane_server}",
    "octane_port": "${octane_port}",
    "schedule": "on",
    "webhook_token": "${webhook_token}",
    "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
JSON
)"
    else
        app_save "$app_user" "$(cat <<JSON
{
    "user": "${app_user}",
    "domain": "${domain}",
    "aliases": [],
    "repository": "${repository}",
    "branch": "${branch}",
    "php": "${php_ver}",
    "engine": "${db_engine}",
    "schedule": "on",
    "webhook_token": "${webhook_token}",
    "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
JSON
)"
    fi
    # Save git integration IDs (if provider was configured)
    if [[ -n "${GIT_PROVIDER:-}" ]]; then
        git_save_app_data "$app_user" "$GIT_PROVIDER" "${GIT_DEPLOY_KEY_ID:-}" "${GIT_WEBHOOK_ID:-}"
    fi
    log_action "APP CREATED: $app_user domain=$domain php=$php_ver engine=${db_engine:-none} octane=${octane_server:-none}"

    # Email notification
    local _notify_repo _notify_branch
    _notify_repo="$repository"
    _notify_branch="$branch"
    if [[ "$app_type" == "custom" && -z "$repository" ]]; then
        _notify_repo="(none — SFTP only)"
        _notify_branch="—"
    fi
    cipi_notify \
        "Cipi app created: ${app_user} on $(hostname)" \
        "A new app was created.\n\nServer: $(hostname)\nApp: ${app_user}\nDomain: ${domain}\nPHP: ${php_ver}\nBranch: ${_notify_branch}\nRepository: ${_notify_repo}\nOctane: ${octane_server:-no}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        app_create

    # 8. Nginx vhost
    step "Nginx vhost..."
    if [[ -n "$octane_server" ]]; then
        _ensure_nginx_octane_map
    fi
    if [[ "$app_type" == "custom" ]]; then
        _create_nginx_vhost "$app_user" "$domain" "$php_ver" "" "custom" "$docroot"
    else
        _create_nginx_vhost "$app_user" "$domain" "$php_ver" ""
    fi
    ln -sf "/etc/nginx/sites-available/${app_user}" "/etc/nginx/sites-enabled/${app_user}"
    reload_nginx
    success "Nginx → ${domain}"

    # 9. Supervisor (Laravel only; Octane program when enabled)
    step "Queue worker..."
    echo "" > "/etc/supervisor/conf.d/${app_user}.conf"
    if [[ "$app_type" == "laravel" ]]; then
        _create_supervisor_worker "$app_user" "$php_ver" "default"
        if [[ -n "$octane_server" ]]; then
            _create_supervisor_octane "$app_user" "$php_ver" "$octane_port"
            reload_supervisor
            success "Worker + Octane (:${octane_port})"
        else
            reload_supervisor
            success "Worker (default queue)"
        fi
    else
        reload_supervisor
        success "Skipped"
    fi

    # 10. Crontab (Laravel only; custom: no cron)
    step "Crontab..."
    if [[ "$app_type" == "custom" ]]; then
        crontab -u "$app_user" -r 2>/dev/null || true
        success "None"
    elif [[ "$app_type" == "laravel" ]]; then
        cat <<CRON | crontab -u "$app_user" -
# Laravel Scheduler
* * * * * /usr/bin/php${php_ver} ${home}/current/artisan schedule:run >> /dev/null 2>&1
# Cipi deploy trigger (written by cipi/agent webhook)
* * * * * test -f ${home}/.deploy-trigger && rm -f ${home}/.deploy-trigger && /usr/local/bin/cipi-app-deploy ${app_user} ${php_ver} webhook >/dev/null 2>&1
CRON
        success "Scheduler + deploy trigger"
    fi

    # 11. Deployer config (dedicated template per app type)
    step "Deployer..."
    if [[ -n "$octane_server" ]]; then
        _create_deployer_config_from_template "laravel-octane" "$app_user" "$repository" "$branch" "$php_ver"
    else
        _create_deployer_config_from_template "$app_type" "$app_user" "$repository" "$branch" "$php_ver"
    fi
    success "Deployer"

    # 12. Sudoers (worker restart only)
    step "Permissions..."
    cat > "/etc/sudoers.d/cipi-${app_user}" <<SUDO
${app_user} ALL=(root) NOPASSWD: /usr/local/bin/cipi-worker restart ${app_user}
${app_user} ALL=(root) NOPASSWD: /usr/local/bin/cipi-worker stop ${app_user}
${app_user} ALL=(root) NOPASSWD: /usr/local/bin/cipi-worker status ${app_user}
${app_user} ALL=(root) NOPASSWD: /usr/local/bin/cipi-app-notify ${app_user} *
${app_user} ALL=(root) NOPASSWD: /usr/local/bin/cipi health postdeploy ${app_user} --auto
${app_user} ALL=(root) NOPASSWD: /usr/local/bin/cipi-scan-manifest ${app_user}
SUDO
    chmod 440 "/etc/sudoers.d/cipi-${app_user}"
    success "Permissions"

    # Summary
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${GREEN}${BOLD}APP CREATED: ${app_user}${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local server_ip; server_ip=$(curl -s --max-time 3 https://checkip.amazonaws.com 2>/dev/null || hostname)
    echo -e "  Domain:     ${CYAN}${domain}${NC}"
    echo -e "  IP:         ${CYAN}${server_ip}${NC}"
    echo -e "  PHP:        ${CYAN}${php_ver}${NC}"
    if [[ -n "$octane_server" ]]; then
        echo -e "  Runtime:    ${CYAN}Octane (${octane_server}) :${octane_port}${NC}"
    else
        echo -e "  Runtime:    ${CYAN}PHP-FPM${NC}"
    fi
    echo -e "  Home:       ${CYAN}${home}${NC}"
    [[ "$app_type" == "custom" ]] && echo -e "  Docroot:    ${CYAN}/${docroot:-}${NC}"
    echo ""
    echo -e "  ${BOLD}SSH${NC}         ${CYAN}${app_user}${NC} / ${CYAN}${user_pass}${NC}"
    if [[ "$app_type" == "laravel" ]]; then
        echo -e "  ${BOLD}Database${NC}    ${CYAN}${app_user}${NC} / ${CYAN}${db_pass}${NC}  ${DIM}($(db_engine_label "$db_engine"))${NC}"
        echo ""
        echo -e "  ${BOLD}$(db_engine_label "$db_engine") URL${NC}"
        echo -e "  ${CYAN}$(db_connection_url "$db_engine" "$app_user" "$user_pass" "$server_ip" "$app_user" "$db_pass" "$app_user")${NC}"
        echo ""
    fi
    if [[ "$app_type" == "custom" ]]; then
        if [[ -n "$repository" ]]; then
            if [[ -n "${GIT_PROVIDER:-}" && -n "${GIT_DEPLOY_KEY_ID:-}" ]]; then
                echo -e "  ${BOLD}Git${NC}         ${GREEN}${GIT_PROVIDER} deploy key ✓${NC}"
            else
                echo -e "  ${BOLD}Deploy Key${NC}  (add to your Git provider)"
                echo -e "  ${CYAN}${deploy_key}${NC}"
                [[ -z "${GIT_PROVIDER:-}" ]] && echo -e "  ${DIM}Tip: cipi git github-token <PAT> to auto-configure next time${NC}"
            fi
            echo ""
            echo -e "  ${BOLD}Next:${NC} cipi deploy ${app_user}"
            echo -e "        cipi ssl install ${app_user}"
        else
            echo -e "  ${BOLD}Deploy${NC}     ${DIM}No Git repository — upload via SFTP to ${home}/htdocs${NC}"
            echo ""
            echo -e "  ${BOLD}Next:${NC} Upload files to ${CYAN}~/htdocs${NC} (SFTP as ${app_user})"
            echo -e "        cipi ssl install ${app_user}"
            echo -e "  ${DIM}Add a repo later: cipi app edit ${app_user} --repository=<SSH-URL>${NC}"
        fi
    elif [[ "$app_type" == "laravel" ]]; then
        if [[ -n "${GIT_PROVIDER:-}" && -n "${GIT_DEPLOY_KEY_ID:-}" && -n "${GIT_WEBHOOK_ID:-}" ]]; then
            echo -e "  ${BOLD}Git${NC}         ${GREEN}${GIT_PROVIDER} auto-configured ✓${NC}"
            echo -e "  ${BOLD}Webhook${NC}     ${CYAN}https://${url_host}/cipi/webhook${NC}"
        else
            echo -e "  ${BOLD}Deploy Key${NC}  (add to your Git provider)"
            echo -e "  ${CYAN}${deploy_key}${NC}"
            echo ""
            echo -e "  ${BOLD}Webhook${NC}     ${CYAN}https://${url_host}/cipi/webhook${NC}"
            echo -e "  ${BOLD}Token${NC}       ${CYAN}${webhook_token}${NC}"
            if [[ -z "${GIT_PROVIDER:-}" ]]; then
                echo ""
                echo -e "  ${DIM}Tip: cipi git github-token <PAT> to auto-configure next time${NC}"
            fi
        fi
        echo ""
        if [[ -n "$octane_server" ]]; then
            echo -e "  ${BOLD}Next:${NC} composer require laravel/octane cipi/agent  (in your Laravel project)"
            echo -e "        php artisan octane:install --server=frankenphp"
            echo -e "        cipi deploy ${app_user}"
            echo -e "        cipi ssl install ${app_user}"
            echo -e "  ${DIM}Octane starts after the first successful deploy (Supervisor).${NC}"
        else
            echo -e "  ${BOLD}Next:${NC} composer require cipi/agent  (in your Laravel project)"
            echo -e "        cipi deploy ${app_user}"
            echo -e "        cipi ssl install ${app_user}"
        fi
    fi
    if domain_is_wildcard "$domain"; then
        echo ""
        echo -e "  ${BOLD}Wildcard${NC}    ${DIM}Let's Encrypt issues *.${NC}${DIM} certificates over DNS-01 only:${NC}"
        echo -e "              ${DIM}cipi ssl dns set --provider=cloudflare --token=<TOKEN>${NC}"
        echo -e "              ${DIM}cipi ssl install ${app_user} --dns=cloudflare${NC}"
    fi
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
    printf "\n${BOLD}%-14s %-28s %-6s %-10s %s${NC}\n" "APP" "DOMAIN" "PHP" "RUNTIME" "CREATED"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$_aj" | jq -r 'to_entries[]|"\(.key)\t\(.value.domain)\t\(.value.php)\t\(.value.created_at)\t\(.value.suspended // "false")\t\(.value.octane // "")"' \
        | while IFS=$'\t' read -r a d p c s o; do
        local st="${GREEN}●${NC}"
        if [[ -n "$o" ]]; then
            supervisorctl status "${a}-octane" 2>/dev/null | grep -q RUNNING || st="${RED}●${NC}"
        else
            systemctl is-active --quiet "php${p}-fpm" 2>/dev/null || st="${RED}●${NC}"
        fi
        [[ "$s" == "true" ]] && st="${YELLOW}●${NC}"
        local suffix=""; [[ "$s" == "true" ]] && suffix=" ${YELLOW}(suspended)${NC}"
        local runtime="fpm"; [[ -n "$o" ]] && runtime="octane"
        printf "  ${st} %-12s %-28s %-6s %-10s %s${suffix}\n" "$a" "$d" "$p" "$runtime" "${c:0:10}"
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

    local is_custom docroot_show
    is_custom=$(app_get "$app" custom)
    docroot_show=$(app_get "$app" docroot)
    echo -e "\n${BOLD}${app}${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    [[ "$is_custom" == "true" ]] && printf "  %-14s ${CYAN}%s${NC}\n" "Type" "Custom"
    [[ "$is_custom" == "true" ]] && [[ -n "$docroot_show" ]] && printf "  %-14s ${CYAN}/%s${NC}\n" "Docroot" "$docroot_show"
    printf "  %-14s ${CYAN}%s${NC}\n" "Domain" "$d"
    printf "  %-14s ${CYAN}%s${NC}\n" "Aliases" "$aliases"
    case "$(app_get "$app" www_redirect)" in
        to-root)   printf "  %-14s ${CYAN}%s${NC}\n" "WWW" "force to-root (www → apex)" ;;
        from-root) printf "  %-14s ${CYAN}%s${NC}\n" "WWW" "force from-root (apex → www)" ;;
    esac
    if [[ "$(app_get "$app" force_https)" == "true" ]]; then
        printf "  %-14s ${GREEN}%s${NC}\n" "HTTPS" "forced (http → https)"
    fi
    printf "  %-14s ${CYAN}%s${NC}\n" "Repository" "$repo"
    printf "  %-14s ${CYAN}%s${NC}\n" "Branch" "$b"
    printf "  %-14s ${CYAN}%s${NC}\n" "PHP" "$p"
    local octane_show octane_port_show
    octane_show=$(app_get "$app" octane)
    octane_port_show=$(app_get "$app" octane_port)
    if [[ -n "$octane_show" ]]; then
        printf "  %-14s ${CYAN}%s${NC} ${DIM}(127.0.0.1:%s)${NC}\n" "Runtime" "Octane (${octane_show})" "${octane_port_show:-?}"
    else
        printf "  %-14s ${CYAN}%s${NC}\n" "Runtime" "PHP-FPM"
    fi
    if [[ "$is_custom" != "true" ]]; then
        local eng; eng=$(app_get "$app" engine); [[ -z "$eng" ]] && eng="mariadb"
        printf "  %-14s ${CYAN}%s${NC}\n" "DB engine" "$eng"
        local sch; sch=$(app_get "$app" schedule); [[ -z "$sch" ]] && sch="on"
        printf "  %-14s ${CYAN}%s${NC}\n" "Schedule" "$sch"
        [[ "$(app_get "$app" horizon)" == "true" ]] && printf "  %-14s ${CYAN}%s${NC}\n" "Queue" "Horizon"
        local rev; rev=$(app_get "$app" reverb)
        [[ -n "$rev" ]] && printf "  %-14s ${CYAN}%s${NC} ${DIM}(127.0.0.1:%s)${NC}\n" "Reverb" "enabled" "$(app_get "$app" reverb_port)"
        local nb; nb=$(app_get "$app" node_build)
        [[ -n "$nb" ]] && printf "  %-14s ${CYAN}%s${NC}\n" "Node build" "$nb"
        [[ "$(app_get "$app" predeploy_snapshot)" == "true" ]] && printf "  %-14s ${CYAN}%s${NC}\n" "DB snapshot" "pre-deploy on"
        local hu; hu=$(app_get "$app" health_url)
        [[ -n "$hu" ]] && printf "  %-14s ${CYAN}%s${NC} ${DIM}(expect %s)${NC}\n" "Health" "$hu" "$(app_get "$app" health_expect)"
        local cloned; cloned=$(app_get "$app" cloned_from)
        [[ -n "$cloned" ]] && printf "  %-14s ${CYAN}%s${NC}\n" "Cloned from" "$cloned"
    fi
    printf "  %-14s ${CYAN}%s${NC}\n" "Created" "$ca"
    if [[ "$(app_get "$app" suspended)" == "true" ]]; then
        printf "  %-14s ${YELLOW}%s${NC}\n" "Status" "suspended (offline)"
    fi
    if [[ "$(app_get "$app" basic_auth)" == "true" ]]; then
        local ba_users; ba_users=$(cut -d: -f1 "/etc/nginx/cipi-basicauth/${app}.htpasswd" 2>/dev/null | paste -sd, -)
        printf "  %-14s ${GREEN}%s${NC}\n" "Basic Auth" "enabled${ba_users:+ (${ba_users})}"
    fi
    local git_prov; git_prov=$(app_get "$app" git_provider)
    if [[ -n "$git_prov" ]]; then
        local git_dkid; git_dkid=$(app_get "$app" git_deploy_key_id)
        local git_whid; git_whid=$(app_get "$app" git_webhook_id)
        printf "  %-14s ${GREEN}%s${NC} (key:%s hook:%s)\n" "Git" "$git_prov" "${git_dkid:-manual}" "${git_whid:-manual}"
    fi

    local show_webhook; show_webhook=$(app_get "$app" webhook_token)
    if [[ -n "$show_webhook" ]] && [[ "$is_custom" != "true" ]]; then
        echo -e "\n  ${BOLD}Webhook${NC}  ${CYAN}https://$(domain_url_host "$d")/cipi/webhook${NC}"
    fi

    if [[ -f "/home/${app}/.ssh/id_ed25519.pub" ]]; then
        echo -e "\n  ${BOLD}Deploy Key${NC}\n  ${CYAN}$(cat "/home/${app}/.ssh/id_ed25519.pub")${NC}"
    fi
    if [[ "$is_custom" != "true" ]] && [[ -L "/home/${app}/current" ]]; then
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
    if [[ -n "$octane_show" ]]; then
        echo -e "\n  ${BOLD}Octane${NC}"
        local octane_st
        octane_st=$(supervisorctl status "${app}-octane" 2>/dev/null || true)
        if [[ -n "$octane_st" ]]; then
            echo "$octane_st" | sed 's/^/  /'
        else
            echo "  not configured"
        fi
    fi
    if [[ -n "$(app_get "$app" reverb)" ]]; then
        echo -e "\n  ${BOLD}Reverb${NC}"
        supervisorctl status "${app}-reverb" 2>/dev/null | sed 's/^/  /' || echo "  not running"
    fi
    if [[ "$(app_get "$app" horizon)" == "true" ]]; then
        echo -e "\n  ${BOLD}Horizon${NC}"
        supervisorctl status "${app}-horizon" 2>/dev/null | sed 's/^/  /' || echo "  not running"
    fi
    echo ""
}

# Change primary domain; the previous primary becomes an alias.
# Returns 0 on success, 1 on error, 2 if the domain is unchanged.
_app_change_domain() {
    local app="$1" new_domain="$2"
    local old_domain php_ver had_ssl=false repo

    old_domain=$(app_get "$app" domain)
    [[ "$new_domain" == "$old_domain" ]] && return 2

    validate_domain_or_wildcard "$new_domain" || { error "Invalid domain '${new_domain}'"; return 1; }
    domain_is_used_by_other_app "$new_domain" "$app" && {
        error "Domain '${new_domain}' is already used by app '${DOMAIN_USED_BY_APP}'"
        return 1
    }

    [[ -d "/etc/letsencrypt/live/$(domain_cert_name "$old_domain")" ]] && had_ssl=true

    step "Domain ${old_domain} → ${new_domain}..."

    vault_read apps.json | jq \
        --arg a "$app" --arg old "$old_domain" --arg new "$new_domain" \
        '.[$a].domain = $new
         | .[$a].aliases = (
             (.[$a].aliases // [])
             | map(select(. != $new))
             | if (index($old) != null) then . else . + [$old] end
             | unique
           )
         | .[$a].www_redirect = ""' | vault_write apps.json
    ensure_apps_json_api_access

    php_ver=$(app_get "$app" php)
    _create_nginx_vhost "$app" "$new_domain" "$php_ver"
    reload_nginx || return 1

    if [[ -f "/home/${app}/shared/.env" ]]; then
        sed -i "s|^APP_URL=.*|APP_URL=https://$(domain_url_host "$new_domain")|" "/home/${app}/shared/.env" 2>/dev/null || true
    fi

    repo=$(app_get "$app" repository)
    if [[ -n "$repo" ]]; then
        source "${CIPI_LIB}/git.sh"
        git_update_webhook_domain "$app" "$(domain_url_host "$new_domain")" "$repo"
    fi

    if [[ "$had_ssl" == true ]] && domain_is_wildcard "$new_domain"; then
        # HTTP-01 cannot validate a wildcard, so reissuing here would only fail:
        # the old certificate is left in place until DNS-01 replaces it.
        warn "'${new_domain}' is a wildcard — reissue over DNS-01: cipi ssl install ${app} --dns=cloudflare"
    elif [[ "$had_ssl" == true ]]; then
        step "Reissuing SSL certificate..."
        certbot delete --cert-name "$(domain_cert_name "$old_domain")" --non-interactive 2>/dev/null || true
        source "${CIPI_LIB}/ssl.sh"
        _ssl_install "$app" || warn "SSL reinstall failed — run: cipi ssl install ${app}"
    else
        info "Run: cipi ssl install ${app}  (after DNS for ${new_domain} is ready)"
    fi

    # REVERB_HOST and VITE_REVERB_HOST named the old domain, so a Reverb app
    # would keep pointing browsers (and its own broadcaster) at it.
    if [[ -n "$(app_get "$app" reverb)" ]]; then
        _reverb_sync_env "$app"
    fi

    success "Domain → ${new_domain} (${old_domain} is now an alias)"
    return 0
}

# ── EDIT ──────────────────────────────────────────────────────

app_edit() {
    local app="${1:-}"; shift || true
    [[ -z "$app" ]] && { error "Usage: cipi app edit <app> [--domain=D] [--php=X.Y] [--branch=B] [--repository=URL] [--node-build=CMD|--no-node-build] [--predeploy-snapshot|--no-predeploy-snapshot]"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    parse_args "$@"
    local changed=false cur_php domain_change_from=""
    cur_php=$(app_get "$app" php)

    if [[ -n "${ARG_domain:-}" ]]; then
        domain_change_from=$(app_get "$app" domain)
        _app_change_domain "$app" "${ARG_domain}"
        local domain_rc=$?
        if [[ "$domain_rc" -eq 0 ]]; then
            changed=true
        elif [[ "$domain_rc" -eq 2 ]]; then
            info "Domain already '${ARG_domain}'"
        else
            exit 1
        fi
    fi

    if [[ -n "${ARG_php:-}" ]]; then
        local np="${ARG_php}"
        if [[ "$np" == "$cur_php" ]]; then
            info "PHP already '${np}'"
        else
            validate_php_version "$np" || { error "Invalid PHP: $np"; exit 1; }
            php_is_installed "$np" || { error "PHP $np not installed. Run: cipi php install $np"; exit 1; }
            step "PHP ${cur_php} → ${np}..."
            if [[ -n "$(app_get "$app" octane)" ]]; then
                # Octane apps have no FPM pool — only CLI paths in supervisor/cron/deployer
                rm -f "/etc/php/${cur_php}/fpm/pool.d/${app}.conf" 2>/dev/null || true
            else
                rm -f "/etc/php/${cur_php}/fpm/pool.d/${app}.conf"
                _create_fpm_pool "$app" "$np"; reload_php_fpm "$cur_php"; reload_php_fpm "$np"
            fi
            sed -i "s|/usr/bin/php[0-9]\.[0-9]|/usr/bin/php${np}|g" "/etc/supervisor/conf.d/${app}.conf" 2>/dev/null
            reload_supervisor
            crontab -u "$app" -l 2>/dev/null | sed "s|php${cur_php}|php${np}|g" | crontab -u "$app" -
            sed -i "s|php${cur_php}|php${np}|g" "/home/${app}/.bashrc" "/home/${app}/.deployer/deploy.php" 2>/dev/null
            if ! grep -q "bin/composer" "/home/${app}/.deployer/deploy.php" 2>/dev/null; then
                sed -i "/set('bin\/php'/a set('bin/composer', '/usr/bin/php${np} /usr/local/bin/composer');" "/home/${app}/.deployer/deploy.php" 2>/dev/null
            fi
            sed -i "s|^CIPI_PHP_VERSION=.*|CIPI_PHP_VERSION=${np}|" "/home/${app}/shared/.env"
            app_set "$app" php "$np"; success "PHP → $np"; changed=true
        fi
    fi
    if [[ -n "${ARG_branch:-}" ]]; then
        local cur_branch; cur_branch=$(app_get "$app" branch)
        if [[ "${ARG_branch}" == "$cur_branch" ]]; then
            info "Branch already '${ARG_branch}'"
        else
            validate_git_branch "${ARG_branch}" || { error "Invalid branch name '${ARG_branch}'"; exit 1; }
            app_set "$app" branch "${ARG_branch}"
            local safe_branch; safe_branch=$(printf '%s' "${ARG_branch}" | sed 's/[&|\\\/]/\\&/g')
            sed -i "s|set('branch', '.*')|set('branch', '${safe_branch}')|" "/home/${app}/.deployer/deploy.php"
            success "Branch → ${ARG_branch}"; changed=true
        fi
    fi
    if [[ -n "${ARG_repository:-}" ]]; then
        validate_git_repository "${ARG_repository}" || { error "Invalid repository URL '${ARG_repository}'"; exit 1; }
        local old_repo; old_repo=$(app_get "$app" repository)
        if [[ "${ARG_repository}" == "$old_repo" ]]; then
            info "Repository already '${ARG_repository}'"
        else
            app_set "$app" repository "${ARG_repository}"
            local safe_repo; safe_repo=$(printf '%s' "${ARG_repository}" | sed 's/[&|\\\/]/\\&/g')
            sed -i "s|set('repository', '.*')|set('repository', '${safe_repo}')|" "/home/${app}/.deployer/deploy.php"

            # Migrate git provider integration only when the URL actually changes
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
    fi
    if [[ -n "${ARG_node_build+x}" || "${ARG_no_node_build:-}" == "true" ]]; then
        if [[ "${ARG_no_node_build:-}" == "true" || -z "${ARG_node_build:-}" ]]; then
            app_unset "$app" node_build
            _sync_node_build_script "$app"
            success "Node build disabled"; changed=true
        else
            _validate_node_build_cmd "${ARG_node_build}" || {
                error "Invalid --node-build. Use npm/npx/yarn/pnpm/bun/node and safe characters only."
                exit 1
            }
            app_set "$app" node_build "${ARG_node_build}"
            _sync_node_build_script "$app"
            _create_deployer_config_for_app "$app"
            success "Node build → ${ARG_node_build}"; changed=true
        fi
    fi
    if [[ "${ARG_predeploy_snapshot:-}" == "true" ]]; then
        app_set "$app" predeploy_snapshot "true"
        success "Pre-deploy DB snapshot enabled"; changed=true
    elif [[ "${ARG_no_predeploy_snapshot:-}" == "true" ]]; then
        app_unset "$app" predeploy_snapshot
        success "Pre-deploy DB snapshot disabled"; changed=true
    fi
    [[ "$changed" == false ]] && info "Nothing changed. Use --domain, --php, --branch, --repository, --node-build, or --predeploy-snapshot"
    if [[ "$changed" == true ]]; then
        log_action "APP EDITED: $app $*"

        # Email notification
        local edit_details=""
        [[ -n "${ARG_domain:-}" && -n "$domain_change_from" && "$domain_change_from" != "${ARG_domain}" ]] \
            && edit_details="${edit_details}Domain: ${domain_change_from} → ${ARG_domain}\n"
        [[ -n "${ARG_php:-}" ]] && edit_details="${edit_details}PHP: ${cur_php} → ${ARG_php}\n"
        [[ -n "${ARG_branch:-}" ]] && edit_details="${edit_details}Branch: ${ARG_branch}\n"
        [[ -n "${ARG_repository:-}" ]] && edit_details="${edit_details}Repository: ${ARG_repository}\n"
        [[ -n "${ARG_node_build+x}" || "${ARG_no_node_build:-}" == "true" ]] && edit_details="${edit_details}Node build updated\n"
        [[ "${ARG_predeploy_snapshot:-}" == "true" || "${ARG_no_predeploy_snapshot:-}" == "true" ]] && edit_details="${edit_details}Predeploy snapshot updated\n"
        cipi_notify \
            "Cipi app modified: ${app} on $(hostname)" \
            "An app was modified.\n\nServer: $(hostname)\nApp: ${app}\nDomain: $(app_get "$app" domain)\n\nChanges:\n${edit_details}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
            app_edit
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

    step "Workers...";     supervisorctl stop "${app}-worker-"* 2>/dev/null||true; supervisorctl stop "${app}-octane" 2>/dev/null||true; supervisorctl stop "${app}-reverb" 2>/dev/null||true; supervisorctl stop "${app}-horizon" 2>/dev/null||true; rm -f "/etc/supervisor/conf.d/${app}.conf"; reload_supervisor
    step "Nginx...";       rm -f "/etc/nginx/sites-enabled/${app}" "/etc/nginx/sites-available/${app}"; reload_nginx
    step "PHP-FPM...";     rm -f "/etc/php/${p}/fpm/pool.d/${app}.conf"; reload_php_fpm "$p" 2>/dev/null||true
    local skip_db; skip_db=false
    [[ "$(app_get "$app" custom)" == "true" ]] && skip_db=true
    if [[ "$skip_db" != "true" ]]; then
        # shellcheck source=/dev/null
        source "${CIPI_LIB}/db.sh"
        local eng; eng=$(app_get "$app" engine); [[ -z "$eng" ]] && eng="mariadb"
        eng=$(db_normalize_engine "$eng" 2>/dev/null || echo "mariadb")
        step "Database ($(db_engine_label "$eng"))..."
        if db_engine_is_installed "$eng"; then
            db_drop_database "$eng" "$app" "$app" || true
        else
            warn "$(db_engine_label "$eng") not installed — skipping DB drop"
        fi
    fi
    # The app's Meilisearch key outlives the Linux user unless it is revoked
    # here: the engine knows nothing about /etc/cipi/apps.json.
    if [[ -f "${CIPI_CONFIG}/search.json" ]]; then
        # shellcheck source=/dev/null
        source "${CIPI_LIB}/search.sh"
        search_cleanup_app "$app" || true
    fi
    step "Crontab...";     crontab -u "$app" -r 2>/dev/null||true
    step "Sudoers...";     rm -f "/etc/sudoers.d/cipi-${app}"
    step "Basic auth...";  rm -f "/etc/nginx/cipi-basicauth/${app}.htpasswd"
    step "SSL...";         certbot delete --cert-name "$(domain_cert_name "$d")" --non-interactive 2>/dev/null||true
    step "User & files..."
    # Kill leftover processes, userdel -r with rm -rf /home/<app> fallback (SSH keys included)
    remove_app_linux_user "$app"
    step "Config...";      app_remove "$app"
    # Sweep leftovers not in apps.json (failed prior deletes / partial userdel)
    purge_orphan_app_users || true

    log_action "APP DELETED: $app"

    # Email notification
    cipi_notify \
        "Cipi app deleted: ${app} on $(hostname)" \
        "An app was deleted.\n\nServer: $(hostname)\nApp: ${app}\nDomain: ${d}\nPHP: ${p}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        app_delete

    echo ""; success "'${app}' deleted"; echo ""
}

# ── ENV / LOGS / TINKER / ARTISAN ─────────────────────────────

# Validate .env key name: [A-Za-z_][A-Za-z0-9_]*
_env_valid_key() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# Escape a value for .env (double-quote when needed).
_env_escape_value() {
    local v="$1"
    if [[ "$v" == *" "* || "$v" == *$'\t'* || "$v" == *"#"* || "$v" == *"\""* || "$v" == *"'"* || "$v" == *"\\"* || "$v" == *'$'* || "$v" == *'`'* || "$v" == *"="* ]]; then
        v="${v//\\/\\\\}"
        v="${v//\"/\\\"}"
        printf '"%s"' "$v"
    else
        printf '%s' "$v"
    fi
}

# Read KEY from .env file into stdout (unquoted). Exit 1 if missing.
_env_read_key() {
    local file="$1" key="$2" line raw
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+ ]]; then
            line="${line#*export }"
            line="${line#"${line%%[![:space:]]*}"}"
        fi
        if [[ "$line" == "${key}="* ]] || [[ "$line" == "${key} ="* ]]; then
            raw="${line#*=}"
            raw="${raw#"${raw%%[![:space:]]*}"}"
            if [[ "$raw" =~ ^\"(.*)\"$ ]]; then
                raw="${BASH_REMATCH[1]}"
                raw="${raw//\\\"/\"}"
                raw="${raw//\\\\/\\}"
            elif [[ "$raw" =~ ^\'(.*)\'$ ]]; then
                raw="${BASH_REMATCH[1]}"
            fi
            printf '%s' "$raw"
            return 0
        fi
    done < "$file"
    return 1
}

# Emit all KEY=VALUE pairs as a JSON object on stdout.
_env_to_json() {
    local file="$1"
    local -a args=()
    local line key raw
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+ ]]; then
            line="${line#*export }"
            line="${line#"${line%%[![:space:]]*}"}"
        fi
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"
        key="${key#"${key%%[![:space:]]*}"}"
        _env_valid_key "$key" || continue
        raw="${line#*=}"
        raw="${raw#"${raw%%[![:space:]]*}"}"
        if [[ "$raw" =~ ^\"(.*)\"$ ]]; then
            raw="${BASH_REMATCH[1]}"
            raw="${raw//\\\"/\"}"
            raw="${raw//\\\\/\\}"
        elif [[ "$raw" =~ ^\'(.*)\'$ ]]; then
            raw="${BASH_REMATCH[1]}"
        fi
        args+=(--arg "$key" "$raw")
    done < "$file"
    if [[ ${#args[@]} -eq 0 ]]; then
        echo '{}'
    else
        jq -n "${args[@]}" '$ARGS.named'
    fi
}

# Set KEY=VALUE in .env (update in place or append). Preserves comments/other lines.
_env_set_key() {
    local file="$1" key="$2" value="$3"
    local escaped tmp found=0 line
    escaped=$(_env_escape_value "$value")
    tmp=$(mktemp)
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "${key}="* ]] || [[ "$line" == "${key} ="* ]] || [[ "$line" == "export ${key}="* ]]; then
            if [[ "$line" == export* ]]; then
                echo "export ${key}=${escaped}" >> "$tmp"
            else
                echo "${key}=${escaped}" >> "$tmp"
            fi
            found=1
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$file"
    if [[ $found -eq 0 ]]; then
        echo "${key}=${escaped}" >> "$tmp"
    fi
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# Remove KEY from .env.
_env_unset_key() {
    local file="$1" key="$2"
    local tmp line
    tmp=$(mktemp)
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "${key}="* ]] || [[ "$line" == "${key} ="* ]] || [[ "$line" == "export ${key}="* ]]; then
            continue
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$file"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

app_env() {
    local app="${1:-}"; shift || true
    [[ -z "$app" ]] && { error "Usage: cipi app env <app> [--show|--get=KEY|--set=K=V|--unset=KEY] [--json]"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    local is_custom; is_custom=$(app_get "$app" custom)
    [[ "$is_custom" == "true" ]] && { error "Custom apps have no .env"; exit 1; }

    local env_file="/home/${app}/shared/.env"
    [[ -f "$env_file" ]] || { error ".env not found at ${env_file}"; exit 1; }

    local want_show=false want_json=false get_key=""
    local -a sets=() unsets=()
    local arg

    for arg in "$@"; do
        case "$arg" in
            --show)  want_show=true ;;
            --json)  want_json=true ;;
            --get=*) get_key="${arg#--get=}" ;;
            --set=*) sets+=("${arg#--set=}") ;;
            --unset=*) unsets+=("${arg#--unset=}") ;;
            --*=*|--*)
                error "Unknown flag: ${arg}"
                echo "Use: cipi app env <app> [--show|--get=KEY|--set=K=V|--unset=KEY] [--json]"
                exit 1
                ;;
            *)
                error "Unexpected argument: ${arg}"
                exit 1
                ;;
        esac
    done

    local noninteractive=false
    [[ "$want_show" == "true" || -n "$get_key" || ${#sets[@]} -gt 0 || ${#unsets[@]} -gt 0 ]] && noninteractive=true

    if [[ "$noninteractive" != "true" ]]; then
        ${EDITOR:-nano} "$env_file"
        chown "${app}:${app}" "$env_file"; chmod 640 "$env_file"
        success ".env updated"
        return 0
    fi

    # Mutations first
    local pair key value
    for pair in "${sets[@]+"${sets[@]}"}"; do
        [[ "$pair" == *=* ]] || { error "Invalid --set (expected KEY=VALUE): ${pair}"; exit 1; }
        key="${pair%%=*}"
        value="${pair#*=}"
        _env_valid_key "$key" || { error "Invalid env key: ${key}"; exit 1; }
        _env_set_key "$env_file" "$key" "$value"
    done
    for key in "${unsets[@]+"${unsets[@]}"}"; do
        _env_valid_key "$key" || { error "Invalid env key: ${key}"; exit 1; }
        _env_unset_key "$env_file" "$key"
    done
    if [[ ${#sets[@]} -gt 0 || ${#unsets[@]} -gt 0 ]]; then
        chown "${app}:${app}" "$env_file"; chmod 640 "$env_file"
        log_action "ENV UPDATED: $app"
    fi

    if [[ -n "$get_key" ]]; then
        _env_valid_key "$get_key" || { error "Invalid env key: ${get_key}"; exit 1; }
        local val
        if ! val=$(_env_read_key "$env_file" "$get_key"); then
            error "Key not found: ${get_key}"
            exit 1
        fi
        if [[ "$want_json" == "true" ]]; then
            jq -n --arg k "$get_key" --arg v "$val" '{($k): $v}'
        else
            printf '%s\n' "$val"
        fi
        return 0
    fi

    # --show, or --json after mutations (API), or human success after set/unset
    if [[ "$want_json" == "true" ]]; then
        _env_to_json "$env_file"
        return 0
    fi

    if [[ "$want_show" == "true" ]]; then
        local line
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line//[[:space:]]/}" ]] && continue
            printf '%s\n' "$line"
        done < "$env_file"
        return 0
    fi

    # set/unset without --json/--show
    success ".env updated"
}

app_logs() {
    local app="${1:-}"; shift||true
    [[ -z "$app" ]] && { error "Usage: cipi app logs <app> [--type=nginx|php|worker|deploy|laravel|all]"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    parse_args "$@"
    local laravel_dir="/home/${app}/shared/storage/logs"
    local is_custom; is_custom=$(app_get "$app" custom)
    case "${ARG_type:-all}" in
        nginx)   tail -f "/home/${app}/logs/nginx-"*.log ;;
        php)     tail -f "/home/${app}/logs/php-fpm-"*.log ;;
        worker)  tail -f "/home/${app}/logs/worker-"*.log ;;
        deploy)  tail -f "/home/${app}/logs/deploy.log" ;;
        laravel) [[ "$is_custom" != "true" ]] && [[ -d "$laravel_dir" ]] && tail -f "${laravel_dir}/"*.log || tail -f "/home/${app}/logs/"*.log ;;
        all)     if [[ "$is_custom" == "true" ]] || [[ ! -d "$laravel_dir" ]]; then tail -f "/home/${app}/logs/"*.log; else tail -f "/home/${app}/logs/"*.log "${laravel_dir}/"*.log; fi ;;
    esac
}

# Non-following paginated snapshot for the panel API (open_basedir blocks PHP reads under /home).
app_logs_read() {
    local app="${1:-}"; shift||true
    [[ -z "$app" ]] && { error "Usage: cipi app logs read <app> [--type=T] [--page=N] [--per-page=N]"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    parse_args "$@"
    local type="${ARG_type:-all}"
    local page="${ARG_page:-1}"
    local per_page="${ARG_per_page:-50}"

    if ! [[ "$page" =~ ^[0-9]+$ && "$per_page" =~ ^[0-9]+$ ]]; then
        error "page and per-page must be positive integers"
        exit 1
    fi

    local home="/home/${app}"
    local logs_dir="${home}/logs"
    local laravel_dir="${home}/shared/storage/logs"
    local is_custom; is_custom=$(app_get "$app" custom)
    local -a patterns=()

    case "$type" in
        nginx)   patterns=("${logs_dir}/nginx-*.log") ;;
        php)     patterns=("${logs_dir}/php-fpm-*.log") ;;
        worker)  patterns=("${logs_dir}/worker-*.log") ;;
        deploy)  patterns=("${logs_dir}/deploy.log") ;;
        laravel)
            if [[ "$is_custom" == "true" ]]; then
                patterns=("${laravel_dir}/*.log" "${logs_dir}/*.log")
            else
                patterns=("${laravel_dir}/*.log")
            fi
            ;;
        all)
            if [[ "$is_custom" == "true" ]]; then
                patterns=("${laravel_dir}/*.log" "${logs_dir}/*.log")
            else
                patterns=("${laravel_dir}/*.log" "${logs_dir}/*.log")
            fi
            ;;
        *) error "Unknown log type: ${type}"; exit 1 ;;
    esac

    local pattern
    for pattern in "${patterns[@]}"; do
        _cipi_emit_log_page "$pattern" "$page" "$per_page"
    done
}

_cipi_emit_log_page() {
    local pattern="$1" page="$2" per_page="$3"
    shopt -s nullglob
    local f
    for f in $pattern; do
        [[ -f "$f" ]] || continue
        local total from_end
        total=$(wc -l < "$f" | tr -d ' \n')
        from_end=$(( page * per_page ))
        echo "===CIPI_LOG_FILE:${f}:${total}==="
        /usr/bin/tail -n "$from_end" "$f" | /usr/bin/head -n "$per_page"
        echo "===CIPI_LOG_END==="
    done
}

app_tinker() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi app tinker <app>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    local is_custom; is_custom=$(app_get "$app" custom)
    [[ "$is_custom" == "true" ]] && { error "Custom apps have no Artisan"; exit 1; }
    local p; p=$(app_get "$app" php)
    sudo -u "$app" /usr/bin/php"$p" "/home/${app}/current/artisan" tinker
}

app_artisan() {
    local app="${1:-}"; shift||true
    [[ -z "$app" ]] && { error "Usage: cipi app artisan <app> <cmd>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    local is_custom; is_custom=$(app_get "$app" custom)
    [[ "$is_custom" == "true" ]] && { error "Custom apps have no Artisan"; exit 1; }
    [[ $# -eq 0 ]] && { error "No artisan command"; exit 1; }
    local p; p=$(app_get "$app" php)
    sudo -u "$app" /usr/bin/php"$p" "/home/${app}/current/artisan" "$@"
}

# Whitelisted binaries for `cipi app run` (panel API / scripts). No shell, no network tools.
# ll → ls -al. Runs as the app user under the app home (current/ or htdocs/ or ~).
_APP_RUN_COMMANDS=(
    composer npm npx yarn pnpm
    ls ll cat head tail pwd du wc file stat tree
    mkdir touch cp mv ln unlink rm rmdir
    tar unzip zip gzip gunzip
    git php node
    which realpath basename dirname find
)

_app_run_is_allowed() {
    local c="$1" x
    for x in "${_APP_RUN_COMMANDS[@]}"; do
        [[ "$x" == "$c" ]] && return 0
    done
    return 1
}

_app_run_print_commands() {
    local c
    if [[ "${1:-}" == "--json" ]]; then
        printf '['
        local first=1
        for c in "${_APP_RUN_COMMANDS[@]}"; do
            [[ $first -eq 1 ]] && first=0 || printf ','
            jq -n --arg c "$c" '$c' | tr -d '\n'
        done
        printf ']\n'
    else
        echo "Allowed commands for: cipi app run <app> <cmd> [args...]"
        echo "Runs as the app user in current/ (Laravel), htdocs/ (custom), or ~."
        echo ""
        for c in "${_APP_RUN_COMMANDS[@]}"; do
            echo "  ${c}"
        done
        echo ""
        echo "Notes: non-interactive only (no nano/vim/less/tinker/ssh/bash)."
        echo "       no shell metacharacters; no path '..'; absolute paths only under /home/<app>."
        echo "       find: -exec/-delete blocked. rm: --no-preserve-root and / blocked. ll = ls -al."
        echo "       git/composer/npm interactive subcommands and tail -f are blocked."
    fi
}

_app_run_validate_arg() {
    local arg="$1" app="$2"
    local home="/home/${app}"
    if [[ "$arg" =~ [\;\|\&\`\$\(\)\<\>$'\n\r'\\] ]]; then
        error "Disallowed characters in argument: ${arg}"
        return 1
    fi
    if [[ "$arg" == *..* ]]; then
        error "Path traversal (..) is not allowed"
        return 1
    fi
    if [[ "$arg" == /* ]]; then
        case "$arg" in
            "${home}"|"${home}"/*) ;;
            *) error "Absolute path outside app home: ${arg}"; return 1 ;;
        esac
    fi
    return 0
}

# Resolve argv for app run after the binary name. Maps ll → ls -al.
# Sets global _APP_RUN_ARGV array.
_app_run_build_argv() {
    local cmd="$1"; shift || true
    _APP_RUN_ARGV=()
    case "$cmd" in
        ll) _APP_RUN_ARGV=(ls -al "$@") ;;
        *)  _APP_RUN_ARGV=("$cmd" "$@") ;;
    esac
}

app_run() {
    # cipi app run --commands [--json]
    # cipi app run <app> <cmd> [args...]
    if [[ "${1:-}" == "--commands" || "${1:-}" == "commands" ]]; then
        shift || true
        parse_args "$@"
        if [[ "${ARG_json:-}" == "true" || "${1:-}" == "--json" ]]; then
            _app_run_print_commands --json
        else
            _app_run_print_commands
        fi
        return 0
    fi

    local app="${1:-}"; shift || true
    local cmd="${1:-}"; shift || true
    [[ -z "$app" || -z "$cmd" ]] && {
        error "Usage: cipi app run <app> <cmd> [args...]  |  cipi app run --commands [--json]"
        exit 1
    }
    app_exists "$app" || { error "Not found"; exit 1; }

    if ! _app_run_is_allowed "$cmd"; then
        error "Command not allowed: ${cmd}"
        info "List allowed commands: cipi app run --commands"
        exit 1
    fi

    local arg
    for arg in "$@"; do
        _app_run_validate_arg "$arg" "$app" || exit 1
    done

    # Reject interactive / dangerous flags (editors, pagers, REPLs are not in the whitelist)
    case "$cmd" in
        find)
            for arg in "$@"; do
                case "$arg" in
                    -exec|-execdir|-ok|-okdir|-delete)
                        error "find flag not allowed: ${arg}"; exit 1 ;;
                esac
            done
            ;;
        rm)
            for arg in "$@"; do
                case "$arg" in
                    --no-preserve-root|/|/home|/home/)
                        error "rm target not allowed: ${arg}"; exit 1 ;;
                esac
            done
            ;;
        php)
            for arg in "$@"; do
                case "$arg" in
                    -a|--interactive|-S|--server|-r|--run|-t)
                        error "php flag not allowed via app run: ${arg}"; exit 1 ;;
                esac
            done
            ;;
        node)
            for arg in "$@"; do
                case "$arg" in
                    -e|--eval|-p|--print|-i|--interactive|--inspect|--inspect-brk)
                        error "node flag not allowed via app run: ${arg}"; exit 1 ;;
                esac
            done
            ;;
        tail)
            for arg in "$@"; do
                case "$arg" in
                    -f|--follow|--follow=*)
                        error "tail --follow is interactive; use app logs instead"; exit 1 ;;
                esac
            done
            ;;
        git)
            # Block interactive git UIs / patch modes
            local prev=""
            for arg in "$@"; do
                case "$arg" in
                    -i|--interactive|-p|--patch|--edit)
                        error "git interactive flag not allowed: ${arg}"; exit 1 ;;
                esac
                if [[ "$prev" == "rebase" || "$prev" == "add" || "$prev" == "checkout" || "$prev" == "reset" || "$prev" == "stash" || "$prev" == "clean" || "$prev" == "commit" ]]; then
                    case "$arg" in
                        -i|--interactive|-p|--patch|-e|--edit)
                            error "git ${prev} ${arg} is interactive; not allowed"; exit 1 ;;
                    esac
                fi
                prev="$arg"
            done
            ;;
        composer)
            for arg in "$@"; do
                case "$arg" in
                    shell|browse|fund)
                        error "composer ${arg} is interactive; not allowed"; exit 1 ;;
                esac
            done
            ;;
        npm|npx|yarn|pnpm)
            for arg in "$@"; do
                case "$arg" in
                    explore|init|login|adduser|edit)
                        error "${cmd} ${arg} is interactive; not allowed"; exit 1 ;;
                esac
            done
            ;;
    esac

    local home="/home/${app}"
    local workdir="$home"
    local is_custom; is_custom=$(app_get "$app" custom)
    if [[ "$is_custom" == "true" ]]; then
        [[ -d "${home}/htdocs" ]] && workdir="${home}/htdocs"
    else
        [[ -d "${home}/current" ]] && workdir="${home}/current"
    fi

    _app_run_build_argv "$cmd" "$@"

    # Force non-interactive environment (no pagers, no prompts).
    # GNU env: options (-C) first, then NAME=VALUE, then COMMAND.
    # Do NOT put `--` after assignments — env would try to exec `--` itself.
    local -a env_vars=(
        CI=true
        DEBIAN_FRONTEND=noninteractive
        GIT_TERMINAL_PROMPT=0
        GIT_PAGER=cat
        PAGER=cat
        COMPOSER_NO_INTERACTION=1
        NPM_CONFIG_YES=true
    )

    # Auto --no-interaction for composer when missing
    if [[ "$cmd" == "composer" ]]; then
        local has_ni=0 a
        for a in "${_APP_RUN_ARGV[@]:1}"; do
            [[ "$a" == "--no-interaction" || "$a" == "-n" ]] && has_ni=1
        done
        [[ $has_ni -eq 0 ]] && _APP_RUN_ARGV+=(--no-interaction)
    fi

    # Run without a login shell so aliases/profile cannot inject code.
    sudo -u "$app" -H -- /usr/bin/env -C "$workdir" "${env_vars[@]}" "${_APP_RUN_ARGV[@]}"
}

# ── ALIAS ─────────────────────────────────────────────────────

# Ensure domain is in the app's aliases[]. Returns 0 if newly added, 1 if already present.
_alias_ensure() {
    local app="$1" dom="$2"
    local primary; primary=$(app_get "$app" domain)
    [[ "$dom" == "$primary" ]] && return 1
    if vault_read apps.json | jq -e --arg a "$app" --arg d "$dom" '(.[$a].aliases // []) | index($d) != null' &>/dev/null; then
        return 1
    fi
    domain_is_used_by_other_app "$dom" "$app" && { error "Domain '${dom}' is already used by app '${DOMAIN_USED_BY_APP}'"; exit 1; }
    validate_domain "$dom" || { error "Invalid domain"; exit 1; }
    vault_read apps.json | jq --arg a "$app" --arg d "$dom" '.[$a].aliases+=[$d]|.[$a].aliases|=unique' | vault_write apps.json
    ensure_apps_json_api_access
    return 0
}

alias_add() {
    local app="${1:-}" dom="${2:-}"
    [[ -z "$app" || -z "$dom" ]] && { error "Usage: cipi alias add <app> <domain>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    validate_domain_or_wildcard "$dom" || { error "Invalid domain"; exit 1; }
    local primary; primary=$(app_get "$app" domain)
    [[ "$dom" == "$primary" ]] && { error "'${dom}' is already the primary domain"; exit 1; }
    domain_is_used_by_other_app "$dom" "$app" && { error "Domain '${dom}' is already used by app '${DOMAIN_USED_BY_APP}'"; exit 1; }
    if vault_read apps.json | jq -e --arg a "$app" --arg d "$dom" '(.[$a].aliases // []) | index($d) != null' &>/dev/null; then
        info "'${dom}' is already an alias of '${app}'"; return
    fi
    vault_read apps.json | jq --arg a "$app" --arg d "$dom" '.[$a].aliases+=[$d]|.[$a].aliases|=unique' | vault_write apps.json
    ensure_apps_json_api_access
    _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)"
    _nginx_reapply_ssl "$app"
    log_action "ALIAS ADDED: $dom → $app"
    cipi_notify \
        "Cipi alias added: ${dom} → ${app} on $(hostname)" \
        "A domain alias was added.\n\nServer: $(hostname)\nApp: ${app}\nAlias: ${dom}\nPrimary: $(app_get "$app" domain)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        alias_add
    success "'${dom}' added to '${app}'"
    info "Run: cipi ssl install ${app}  (to update certificate)"
}

alias_remove() {
    local app="${1:-}" dom="${2:-}"
    [[ -z "$app" || -z "$dom" ]] && { error "Usage: cipi alias remove <app> <domain>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }

    local www_mode
    www_mode=$(app_get "$app" www_redirect)
    if [[ "$www_mode" == "to-root" || "$www_mode" == "from-root" ]]; then
        _www_resolve_pair "$(app_get "$app" domain)"
        if [[ "$dom" == "$WWW_PAIR_APEX" || "$dom" == "$WWW_PAIR_HOST" ]]; then
            error "Alias '${dom}' is required by www redirect (${www_mode}). Run: cipi www clear ${app}"
            exit 1
        fi
    fi

    vault_read apps.json | jq --arg a "$app" --arg d "$dom" '.[$a].aliases-=[$d]' | vault_write apps.json
    ensure_apps_json_api_access
    _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)"
    _nginx_reapply_ssl "$app"
    log_action "ALIAS REMOVED: $dom ← $app"
    cipi_notify \
        "Cipi alias removed: ${dom} from ${app} on $(hostname)" \
        "A domain alias was removed.\n\nServer: $(hostname)\nApp: ${app}\nAlias: ${dom}\nPrimary: $(app_get "$app" domain)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        alias_remove
    success "'${dom}' removed from '${app}'"
}

alias_list() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi alias list <app>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    echo -e "\n${BOLD}Domains for '${app}'${NC}"
    echo -e "  Primary: ${CYAN}$(app_get "$app" domain)${NC}"
    vault_read apps.json | jq -r --arg a "$app" '.[$a].aliases // [] | .[]' | while read -r a; do
        echo -e "  Alias:   ${CYAN}${a}${NC}"
    done
    local www_mode; www_mode=$(app_get "$app" www_redirect)
    case "$www_mode" in
        to-root)   echo -e "  WWW:     ${CYAN}force to-root${NC} (www → apex)" ;;
        from-root) echo -e "  WWW:     ${CYAN}force from-root${NC} (apex → www)" ;;
    esac
    echo ""
}

# ── WWW (canonical www / apex redirects) ──────────────────────
# Sets WWW_PAIR_APEX and WWW_PAIR_HOST from a primary domain.
_www_resolve_pair() {
    local primary="$1"
    if [[ "$primary" == www.* ]]; then
        WWW_PAIR_HOST="$primary"
        WWW_PAIR_APEX="${primary#www.}"
    else
        WWW_PAIR_APEX="$primary"
        WWW_PAIR_HOST="www.${primary}"
    fi
}

# A wildcard primary ("*.example.com") has no apex/www pair: prefixing it gives
# "www.*.example.com", which is not a hostname and which nginx would refuse.
_www_reject_wildcard() {
    local app="$1" primary
    primary=$(app_get "$app" domain)
    if domain_is_wildcard "$primary"; then
        error "'${app}' is served on the wildcard domain '${primary}' — there is no www/apex pair to redirect"
        return 1
    fi
    return 0
}

# Ensure the apex/www counterpart of the primary is present as an alias.
_www_ensure_pair() {
    local app="$1" primary other
    primary=$(app_get "$app" domain)
    _www_resolve_pair "$primary"
    if [[ "$primary" == "$WWW_PAIR_HOST" ]]; then other="$WWW_PAIR_APEX"; else other="$WWW_PAIR_HOST"; fi
    if _alias_ensure "$app" "$other"; then
        info "Added alias '${other}'"
        return 0
    fi
    return 1
}

www_add() {
    local app="${1:-}"
    [[ -z "$app" ]] && { error "Usage: cipi www add <app>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }

    local primary other
    primary=$(app_get "$app" domain)
    _www_resolve_pair "$primary"
    if [[ "$primary" == "$WWW_PAIR_HOST" ]]; then other="$WWW_PAIR_APEX"; else other="$WWW_PAIR_HOST"; fi

    if [[ -z "$other" || "$other" == "$primary" ]]; then
        error "Cannot derive www/apex pair from '${primary}'"; exit 1
    fi

    if ! _alias_ensure "$app" "$other"; then
        info "'${other}' is already configured for '${app}'"
        return
    fi

    _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)"
    _nginx_reapply_ssl "$app"
    log_action "WWW ADDED: $other → $app"
    cipi_notify \
        "Cipi www alias added: ${other} → ${app} on $(hostname)" \
        "A www/apex alias was added.\n\nServer: $(hostname)\nApp: ${app}\nAlias: ${other}\nPrimary: ${primary}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        www_add
    success "'${other}' added to '${app}'"
    info "Run: cipi ssl install ${app}  (to update certificate)"
}

www_force_to_root() {
    local app="${1:-}"
    [[ -z "$app" ]] && { error "Usage: cipi www force-to-root <app>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    _www_reject_wildcard "$app" || exit 1

    _www_ensure_pair "$app" || true
    _www_resolve_pair "$(app_get "$app" domain)"

    app_set "$app" www_redirect "to-root"
    _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)"
    _nginx_reapply_ssl "$app"
    log_action "WWW FORCE TO-ROOT: $app (${WWW_PAIR_HOST} → ${WWW_PAIR_APEX})"
    cipi_notify \
        "Cipi www force to-root: ${app} on $(hostname)" \
        "WWW canonical redirect enabled (www → apex).\n\nServer: $(hostname)\nApp: ${app}\nRedirect: ${WWW_PAIR_HOST} → ${WWW_PAIR_APEX}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        www_force_to_root
    success "WWW redirect: ${WWW_PAIR_HOST} → ${WWW_PAIR_APEX}"
}

www_force_from_root() {
    local app="${1:-}"
    [[ -z "$app" ]] && { error "Usage: cipi www force-from-root <app>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }
    _www_reject_wildcard "$app" || exit 1

    _www_ensure_pair "$app" || true
    _www_resolve_pair "$(app_get "$app" domain)"

    app_set "$app" www_redirect "from-root"
    _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)"
    _nginx_reapply_ssl "$app"
    log_action "WWW FORCE FROM-ROOT: $app (${WWW_PAIR_APEX} → ${WWW_PAIR_HOST})"
    cipi_notify \
        "Cipi www force from-root: ${app} on $(hostname)" \
        "WWW canonical redirect enabled (apex → www).\n\nServer: $(hostname)\nApp: ${app}\nRedirect: ${WWW_PAIR_APEX} → ${WWW_PAIR_HOST}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        www_force_from_root
    success "WWW redirect: ${WWW_PAIR_APEX} → ${WWW_PAIR_HOST}"
}

www_clear() {
    local app="${1:-}"
    [[ -z "$app" ]] && { error "Usage: cipi www clear <app>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }

    local mode; mode=$(app_get "$app" www_redirect)
    if [[ "$mode" != "to-root" && "$mode" != "from-root" ]]; then
        info "No www redirect configured for '${app}'"; return
    fi

    app_set "$app" www_redirect ""
    _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)"
    _nginx_reapply_ssl "$app"
    log_action "WWW CLEAR: $app"
    cipi_notify \
        "Cipi www redirect cleared: ${app} on $(hostname)" \
        "WWW canonical redirect was cleared.\n\nServer: $(hostname)\nApp: ${app}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        www_clear
    success "WWW redirect cleared for '${app}'"
}

www_status() {
    local app="${1:-}"
    [[ -z "$app" ]] && { error "Usage: cipi www status <app>"; exit 1; }
    app_exists "$app" || { error "Not found"; exit 1; }

    local primary mode
    primary=$(app_get "$app" domain)
    _www_resolve_pair "$primary"
    mode=$(app_get "$app" www_redirect)

    echo -e "\n${BOLD}WWW — ${app}${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-14s ${CYAN}%s${NC}\n" "Primary" "$primary"
    printf "  %-14s ${CYAN}%s${NC}\n" "Apex" "$WWW_PAIR_APEX"
    printf "  %-14s ${CYAN}%s${NC}\n" "WWW" "$WWW_PAIR_HOST"
    case "$mode" in
        to-root)   printf "  %-14s ${GREEN}%s${NC}\n" "Redirect" "to-root (${WWW_PAIR_HOST} → ${WWW_PAIR_APEX})" ;;
        from-root) printf "  %-14s ${GREEN}%s${NC}\n" "Redirect" "from-root (${WWW_PAIR_APEX} → ${WWW_PAIR_HOST})" ;;
        *)         printf "  %-14s ${DIM}%s${NC}\n" "Redirect" "none" ;;
    esac
    echo ""
}

# ── DOMAINS (global mapping) ──────────────────────────────────

# Show every domain and alias across all apps in one table, mapping each name
# to its owning app, kind (primary/alias), app type (Laravel/custom), PHP
# version, web docroot, SSL status (Let's Encrypt live cert for that exact
# name) and the Git repository (or "(SFTP only)" for custom apps with no repo).
domains_list() {
    local _aj; _aj=$(vault_read apps.json)
    if [[ -z "$_aj" || $(echo "$_aj" | jq 'length') -eq 0 ]]; then
        info "No apps. Create one: cipi app create"; return
    fi

    printf "\n${BOLD}%-26s %-10s %-7s %-7s %-4s %-11s %-12s %-12s %-4s %s${NC}\n" \
        "DOMAIN" "APP" "KIND" "TYPE" "PHP" "DOCROOT" "BRANCH" "LAST DEPLOY" "SSL" "REPOSITORY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local total=0 secured=0
    # Per row: domain \t app \t kind \t type \t php \t docroot \t branch \t repoflag \t repotext
    # (primary first, then each alias), sorted by domain. Every field is emitted
    # non-empty so `read` (tab is IFS whitespace) cannot collapse blank columns.
    # LAST DEPLOY is derived in bash from the mtime of the app's `current`
    # symlink (Deployer atomically re-points it on every successful deploy).
    while IFS=$'\t' read -r dom app kind type php docroot branch repoflag repotext susp; do
        [[ -z "$dom" ]] && continue
        total=$((total + 1))

        local ssl="${RED}✗${NC}"
        if [[ -d "/etc/letsencrypt/live/$(domain_cert_name "$dom")" ]]; then
            ssl="${GREEN}✓${NC}"; secured=$((secured + 1))
        fi

        local deploy="-" cur="/home/${app}/current"
        if [[ -L "$cur" ]]; then
            local ep; ep=$(stat -c %Y "$cur" 2>/dev/null || echo "")
            if [[ -n "$ep" ]]; then
                local now diff; now=$(date +%s); diff=$(( now - ep ))
                (( diff < 0 )) && diff=0
                if   (( diff < 60 ));       then deploy="just now"
                elif (( diff < 3600 ));     then deploy="$(( diff / 60 ))m ago"
                elif (( diff < 86400 ));    then deploy="$(( diff / 3600 ))h ago"
                elif (( diff < 604800 ));   then deploy="$(( diff / 86400 ))d ago"
                elif (( diff < 2592000 ));  then deploy="$(( diff / 604800 ))w ago"
                elif (( diff < 31536000 )); then deploy="$(( diff / 2592000 ))mo ago"
                else                             deploy="$(( diff / 31536000 ))y ago"
                fi
            fi
        fi

        local repo_disp
        if [[ "$repoflag" == "real" ]]; then
            repo_disp="${CYAN}${repotext}${NC}"
        else
            repo_disp="${DIM}${repotext}${NC}"
        fi

        local susp_disp=""
        [[ "$susp" == "true" ]] && susp_disp="  ${YELLOW}⏸ suspended${NC}"

        printf "  %-26s %-10s %-7s %-7s %-4s %-11s %-12s %-12s %b    %b%b\n" \
            "$dom" "$app" "$kind" "$type" "$php" "$docroot" "$branch" "$deploy" "$ssl" "$repo_disp" "$susp_disp"
    done < <(echo "$_aj" | jq -r '
        to_entries[]
        | .key as $app | .value as $v
        | (if $v.custom == true then "Custom" else "Laravel" end) as $type
        | (if $v.custom == true then ("/" + ($v.docroot // "")) else "public" end) as $docroot
        | (if (($v.branch // "") | length) > 0 then $v.branch else "-" end) as $branch
        | ($v.repository // "") as $repo
        | (if ($repo | length) > 0 then "real" elif $v.custom == true then "sftp" else "none" end) as $repoflag
        | (if ($repo | length) > 0 then $repo elif $v.custom == true then "(SFTP only)" else "-" end) as $repotext
        | (if $v.suspended == "true" then "true" else "false" end) as $susp
        | ([{d: $v.domain, t: "primary"}]
           + (($v.aliases // []) | map({d: ., t: "alias"})))[]
        | [.d, $app, .t, $type, ($v.php // "?"), $docroot, $branch, $repoflag, $repotext, $susp] | @tsv
    ' | sort -t$'\t' -k1,1)

    local susp_count; susp_count=$(echo "$_aj" | jq '[.[] | select(.suspended == "true")] | length')
    local susp_note=""; [[ "$susp_count" -gt 0 ]] && susp_note=" — ${susp_count} suspended"
    echo ""
    printf "  ${DIM}%d domain(s) across %d app(s) — %d with SSL%s${NC}\n\n" \
        "$total" "$(echo "$_aj" | jq 'length')" "$secured" "$susp_note"
}

domains_command() {
    local sub="${1:-}"
    case "$sub" in
        ""|list|ls) domains_list ;;
        *) error "Unknown: $sub"; echo "Usage: cipi domains"; exit 1 ;;
    esac
}

# ── HELPERS ───────────────────────────────────────────────────

# php.ini settings that take php_admin_flag (On/Off) rather than php_admin_value.
# Kept in step with the `flag` type in lib/ini.sh.
_fpm_pool_flag_keys() {
    cat <<'EOF'
display_errors
log_errors
zlib.output_compression
expose_php
opcache.enable
opcache.enable_cli
opcache.validate_timestamps
EOF
}

_create_fpm_pool() {
    local app="$1" v="$2"
    local max_children memory_limit start_servers
    max_children=$(_app_limit "$app" fpm_max_children 5 50)
    # Only an *explicit* per-app limit is written into the pool. A pool-level
    # php_admin_value outranks conf.d/99-cipi.ini, so hardcoding the defaults
    # here made `cipi ini set` server-wide look like it did nothing for apps.
    memory_limit=$(vault_read apps.json | jq -r --arg a "$app" '.[$a].limits.memory_limit // empty' 2>/dev/null || true)
    # Derive start_servers from max_children (keep pool small when capped low)
    start_servers=2
    (( max_children < 3 )) && start_servers=1
    (( max_children >= 10 )) && start_servers=3

    # Per-app php.ini overrides (cipi ini set <key>=<value> --app=<app>).
    local overrides="" k val flags
    flags=$(_fpm_pool_flag_keys)
    if [[ -n "$memory_limit" ]]; then
        overrides="${overrides}php_admin_value[memory_limit] = ${memory_limit}"$'\n'
    fi
    while IFS=$'\t' read -r k val; do
        [[ -n "$k" ]] || continue
        [[ "$k" == "memory_limit" && -n "$memory_limit" ]] && continue
        if grep -qx -- "$k" <<< "$flags"; then
            overrides="${overrides}php_admin_flag[${k}] = ${val}"$'\n'
        else
            overrides="${overrides}php_admin_value[${k}] = ${val}"$'\n'
        fi
    done < <(vault_read apps.json | jq -r --arg a "$app" \
        '(.[$a].ini // {}) | to_entries[] | "\(.key)\t\(.value)"' 2>/dev/null || true)

    cat > "/etc/php/${v}/fpm/pool.d/${app}.conf" <<EOF
[${app}]
user = ${app}
group = ${app}
listen = /run/php/${app}.sock
listen.owner = ${app}
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = ${max_children}
pm.start_servers = ${start_servers}
pm.min_spare_servers = 1
pm.max_spare_servers = ${start_servers}
pm.max_requests = 500
request_terminate_timeout = 300
php_admin_value[open_basedir] = /home/${app}/:/tmp/:/proc/
php_admin_value[error_log] = /home/${app}/logs/php-fpm-error.log
php_admin_flag[log_errors] = on
EOF
    # Appended after the heredoc, not inside it: a heredoc only ends on a line
    # holding the delimiter *alone*, so the old `${overrides}EOF` never closed
    # it — the body ran on and swallowed the next function whole.
    if [[ -n "$overrides" ]]; then
        printf '%s' "$overrides" >> "/etc/php/${v}/fpm/pool.d/${app}.conf"
    fi
    return 0
}

# Nginx location block for Laravel Reverb (WebSockets) when enabled.
#
# The path is a *regex* location, not the bare `location /app` this used to be.
# In nginx a prefix location matches everything that starts with it, so `/app`
# also swallowed `/appointments`, `/apple` and `/application/...` and proxied
# real Laravel routes into Reverb. `~ ^/apps?(/|$)` matches only the two paths
# the Pusher protocol actually uses — `/app/{key}` for the WebSocket handshake
# and `/apps/{id}/...` for the HTTP API the application broadcasts through —
# and, being a regex written before `location ~ \.php$`, it is the one nginx
# picks for those. An app that has its own `/app` or `/apps` route cannot use
# Reverb behind the same domain: the protocol fixes these paths.
#
# proxy_read_timeout has to sit above Reverb's ping interval (60s by default).
# An idle connection sees traffic only when Reverb pings it, so the 60s this
# block used to carry was a coin flip on every idle client. Reverb prunes the
# connections that stop answering its pings, so it — not nginx — is what reaps
# dead clients here.
_nginx_reverb_location_block() {
    local app="$1"
    local port
    port=$(app_get "$app" reverb_port)
    [[ -z "$port" ]] && return 0
    _ensure_nginx_octane_map
    cat <<EOF
    location ~ ^/apps?(/|\$) {
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header Scheme \$scheme;
        proxy_set_header SERVER_PORT \$server_port;
        proxy_set_header REMOTE_ADDR \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_pass http://127.0.0.1:${port};
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
EOF
}

# ── SUSPEND (offline page) ────────────────────────────────────
# `cipi app suspend <app>` takes a site offline by replacing its vhost with a
# generic static suspension page served with HTTP 503. State lives in apps.json
# ("suspended": "true") and _create_nginx_vhost renders the suspended vhost when
# the flag is set, so suspension survives vhost regeneration (alias/PHP edits)
# and certbot clones it into the :443 block — HTTPS is covered too. The page is
# shared by all apps and created on demand below.
[[ -z "${SUSPENDED_DIR:-}" ]] && readonly SUSPENDED_DIR="/var/www/cipi-suspended"

# Create (once) the generic static suspension page served to visitors of a
# suspended app. Idempotent — only writes the file when missing.
_ensure_suspended_page() {
    mkdir -p "$SUSPENDED_DIR"
    if [[ ! -f "${SUSPENDED_DIR}/index.html" ]]; then
        cat > "${SUSPENDED_DIR}/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex, nofollow">
    <title>Service Temporarily Unavailable</title>
    <style>
        :root { color-scheme: light dark; }
        * { box-sizing: border-box; }
        body {
            margin: 0;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background: #0f172a;
            color: #e2e8f0;
            padding: 24px;
        }
        .card {
            max-width: 520px;
            width: 100%;
            text-align: center;
            background: #1e293b;
            border: 1px solid #334155;
            border-radius: 16px;
            padding: 48px 40px;
            box-shadow: 0 20px 60px rgba(0, 0, 0, 0.35);
        }
        .badge {
            display: inline-block;
            font-size: 13px;
            letter-spacing: 0.08em;
            text-transform: uppercase;
            color: #fbbf24;
            border: 1px solid #fbbf24;
            border-radius: 999px;
            padding: 4px 14px;
            margin-bottom: 24px;
        }
        h1 { font-size: 26px; margin: 0 0 12px; color: #f8fafc; }
        p { font-size: 16px; line-height: 1.6; margin: 0; color: #94a3b8; }
    </style>
</head>
<body>
    <div class="card">
        <span class="badge">Suspended</span>
        <h1>This site is temporarily unavailable</h1>
        <p>The service for this website has been suspended. Please contact the site administrator or your hosting provider for more information.</p>
    </div>
</body>
</html>
HTML
        chmod 644 "${SUSPENDED_DIR}/index.html"
    fi
    chmod 755 "$SUSPENDED_DIR"
}

_create_nginx_vhost() {
    local app="$1" domain="$2" v="$3"
    local names aliases_raw vhost_type docroot
    if [[ $# -ge 4 ]]; then
        aliases_raw="${4:-}"
    else
        aliases_raw=$(vault_read apps.json | jq -r --arg a "$app" --arg d "$domain" '.[$a].aliases // [] | map(select(. != $d)) | .[]' 2>/dev/null || true)
    fi
    if [[ $# -ge 5 && -n "${5:-}" ]]; then
        vhost_type="${5}"
        docroot="${6:-}"
    else
        if [[ "$(app_get "$app" custom)" == "true" ]]; then
            vhost_type="custom"
            docroot=$(app_get "$app" docroot)
        else
            vhost_type="laravel"; docroot=""
        fi
    fi
    names=$(echo -e "${domain}\n${aliases_raw}" | grep -v '^[[:space:]]*$' | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ $//')

    # Suspended app (cipi app suspend <app>): override the vhost with a generic
    # static page returned as HTTP 503 for every request. The ACME challenge path
    # is kept reachable so SSL issuance/renewal keeps working while suspended.
    # certbot clones these blocks into the :443 server, so HTTPS is suspended too.
    if [[ "$(app_get "$app" suspended)" == "true" ]]; then
        _ensure_suspended_page
        cat > "/etc/nginx/sites-available/${app}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${names};
    root ${SUSPENDED_DIR};
    access_log /home/${app}/logs/nginx-access.log;
    error_log /home/${app}/logs/nginx-error.log;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Cache-Control "no-store, no-cache, must-revalidate" always;
    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        try_files \$uri =404;
    }
    location / {
        return 503;
    }
    error_page 503 /index.html;
    location = /index.html { internal; }
}
EOF
        return 0
    fi

    # WWW canonical redirect (cipi www force-to-root|force-from-root). Emits a
    # dedicated server block for the non-canonical host; the app block keeps the
    # remaining names. ACME stays public on the redirect host. certbot install
    # clones both blocks into :443 so HTTPS inherits the same redirect.
    local www_redirect_block="" www_mode
    www_mode=$(app_get "$app" www_redirect)
    if [[ "$www_mode" == "to-root" || "$www_mode" == "from-root" ]]; then
        local canonical redirect_from redir_scheme
        _www_resolve_pair "$domain"
        if [[ "$www_mode" == "to-root" ]]; then
            canonical="$WWW_PAIR_APEX"
            redirect_from="$WWW_PAIR_HOST"
        else
            canonical="$WWW_PAIR_HOST"
            redirect_from="$WWW_PAIR_APEX"
        fi
        # Drop the redirect host from the app server_name list.
        names=$(echo "$names" | tr ' ' '\n' | grep -vxF "$redirect_from" | grep -v '^[[:space:]]*$' | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ $//')
        if [[ -z "$names" ]]; then
            names="$canonical"
        fi
        redir_scheme="http"
        [[ -d "/etc/letsencrypt/live/$(domain_cert_name "$domain")" ]] && redir_scheme="https"
        www_redirect_block=$(cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${redirect_from};
    access_log /home/${app}/logs/nginx-access.log;
    error_log /home/${app}/logs/nginx-error.log;
    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/html;
        try_files \$uri =404;
    }
    location / {
        return 301 ${redir_scheme}://${canonical}\$request_uri;
    }
}

EOF
)
    fi

    # HTTP basic auth (cipi basicauth enable <app>). Injected into the app's
    # location blocks — NOT at server level — so that certbot's auto-generated
    # ACME challenge location (exact match, inherits from server) stays public
    # and SSL issue/renewal keeps working. certbot clones these location blocks
    # into the :443 server, so HTTPS is protected too.
    local auth_block=""
    if [[ "$(app_get "$app" basic_auth)" == "true" ]] && [[ -f "/etc/nginx/cipi-basicauth/${app}.htpasswd" ]]; then
        auth_block="        auth_basic \"Restricted\";
        auth_basic_user_file /etc/nginx/cipi-basicauth/${app}.htpasswd;
"
    fi
    local root_path="/home/${app}/current"
    if [[ "$vhost_type" == "custom" ]]; then
        root_path="/home/${app}/htdocs"
        [[ -n "$docroot" ]] && root_path="${root_path}/${docroot}"
    else
        [[ -n "$docroot" ]] && root_path="${root_path}/${docroot}"
    fi

    local octane_server octane_port
    octane_server=$(app_get "$app" octane)
    octane_port=$(app_get "$app" octane_port)
    local reverb_block=""
    reverb_block=$(_nginx_reverb_location_block "$app")

    if [[ "$vhost_type" == "custom" ]]; then
        cat > "/etc/nginx/sites-available/${app}" <<EOF
${www_redirect_block}server {
    listen 80;
    listen [::]:80;
    server_name ${names};
    root ${root_path};
    index index.html index.php;
    access_log /home/${app}/logs/nginx-access.log;
    error_log /home/${app}/logs/nginx-error.log;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    client_max_body_size 256M;
${reverb_block}    location / {
${auth_block}        try_files \$uri \$uri/ /index.php?\$args;
    }
    location ~ \.php$ {
${auth_block}        fastcgi_pass unix:/run/php/${app}.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
        fastcgi_read_timeout 300;
    }
    location ~ /\.(?!well-known) { deny all; }
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }
    error_page 404 /404.html;
}
EOF
    elif [[ -n "$octane_server" && -n "$octane_port" ]]; then
        _ensure_nginx_octane_map
        cat > "/etc/nginx/sites-available/${app}" <<EOF
${www_redirect_block}server {
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
${reverb_block}    location /index.php {
${auth_block}        try_files /not_exists @octane;
    }
    location / {
${auth_block}        try_files \$uri \$uri/ @octane;
    }
    location @octane {
${auth_block}        set \$suffix "";
        if (\$uri = /index.php) {
            set \$suffix ?\$query_string;
        }
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header Scheme \$scheme;
        proxy_set_header SERVER_PORT \$server_port;
        proxy_set_header REMOTE_ADDR \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_pass http://127.0.0.1:${octane_port}\$suffix;
        proxy_read_timeout 300;
    }
    location ~ /\.(?!well-known) { deny all; }
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }
    error_page 404 /index.php;
}
EOF
    else
        cat > "/etc/nginx/sites-available/${app}" <<EOF
${www_redirect_block}server {
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
${reverb_block}    location / {
${auth_block}        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php$ {
${auth_block}        fastcgi_pass unix:/run/php/${app}.sock;
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
    fi
}


# Deploy-config defaults (apps.json). Missing key = enabled / default.
_deploy_cfg_bool() {
    # $1=app $2=key $3=default true|false — echoes true|false
    local app="$1" key="$2" def="${3:-true}" val
    val=$(app_get "$app" "$key")
    if [[ -z "$val" ]]; then echo "$def"; return; fi
    [[ "$val" == "false" || "$val" == "0" ]] && echo "false" || echo "true"
}

_deploy_cfg_keep_releases() {
    local app="$1" kr
    kr=$(app_get "$app" keep_releases)
    [[ -z "$kr" ]] && kr=5
    [[ "$kr" =~ ^[0-9]+$ ]] && (( kr >= 1 && kr <= 20 )) || kr=5
    echo "$kr"
}

# Validate a single extra artisan token (name only, no args/shell).
_deploy_cfg_valid_artisan() {
    local c="$1"
    [[ "$c" =~ ^[a-zA-Z0-9:_-]+$ ]] || return 1
    [[ "${c,,}" == "tinker" ]] && return 1
    return 0
}

# Build PHP run() lines for extra_artisan (JSON array in apps.json).
_deploy_cfg_extra_artisan_body() {
    local app="$1" cmd force
    while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue
        _deploy_cfg_valid_artisan "$cmd" || continue
        force=""
        case "$cmd" in
            db:seed|migrate|migrate:*|db:wipe) force=" --force" ;;
        esac
        printf "    run('{{bin/php}} {{release_path}}/artisan %s%s');\n" "$cmd" "$force"
    done < <(vault_read apps.json | jq -r --arg a "$app" '.[$a].extra_artisan // [] | .[]?' 2>/dev/null || true)
}

# Deployer: dedicated template per app type (lib/deployer/{laravel,custom}.php)
_create_deployer_config_from_template() {
    local type="$1" an="$2" repo="$3" branch="$4" v="$5"
    local dh="/home/${an}"
    local tpl="${CIPI_LIB}/deployer/${type}.php"
    [[ -f "$tpl" ]] || { error "Deployer template not found: $tpl"; return 1; }
    mkdir -p "${dh}/.deployer"

    local repo_safe branch_safe
    repo_safe=$(printf '%s' "$repo" | sed 's/\\/\\\\/g; s/&/\\&/g')
    branch_safe=$(printf '%s' "$branch" | sed 's/\\/\\\\/g; s/&/\\&/g')

    # Custom apps: classic template has no recipe hooks / keep_releases placeholders
    if [[ "$type" == "custom" ]]; then
        sed -e "s|__CIPI_APP_USER__|$an|g" \
            -e "s|__CIPI_DEPLOY_PATH__|$dh|g" \
            -e "s|__CIPI_PHP_VERSION__|$v|g" \
            -e "s|__CIPI_REPOSITORY__|$repo_safe|g" \
            -e "s|__CIPI_BRANCH__|$branch_safe|g" \
            "$tpl" > "${dh}/.deployer/deploy.php"
        chown -R "${an}:${an}" "${dh}/.deployer"
        return 0
    fi

    local kr shared_files
    kr=$(_deploy_cfg_keep_releases "$an")
    if [[ -f "${dh}/shared/auth.json" ]]; then
        shared_files="['.env', 'auth.json']"
    else
        shared_files="['.env']"
    fi

    local h_storage h_migrate h_optimize h_horizon h_queue h_extra
    [[ "$(_deploy_cfg_bool "$an" deploy_storage_link true)" == "true" ]] \
        && h_storage="after('deploy:vendors', 'artisan:storage:link');" \
        || h_storage="// artisan:storage:link disabled (deploy-config)"
    [[ "$(_deploy_cfg_bool "$an" deploy_migrate true)" == "true" ]] \
        && h_migrate="after('deploy:vendors', 'artisan:migrate');" \
        || h_migrate="// artisan:migrate disabled (deploy-config)"
    [[ "$(_deploy_cfg_bool "$an" deploy_optimize true)" == "true" ]] \
        && h_optimize="after('deploy:vendors', 'artisan:optimize');" \
        || h_optimize="// artisan:optimize disabled (deploy-config)"
    [[ "$(_deploy_cfg_bool "$an" deploy_horizon_terminate true)" == "true" ]] \
        && h_horizon="before('deploy:symlink', 'horizon:terminate');" \
        || h_horizon="// horizon:terminate disabled (deploy-config)"
    [[ "$(_deploy_cfg_bool "$an" deploy_queue_restart true)" == "true" ]] \
        && h_queue="after('deploy:symlink', 'artisan:queue:restart');" \
        || h_queue="// artisan:queue:restart disabled (deploy-config)"

    local extra_body extra_task
    extra_body=$(_deploy_cfg_extra_artisan_body "$an")
    if [[ -n "$extra_body" ]]; then
        h_extra="after('deploy:vendors', 'cipi:extra_artisan');"
        extra_task=$(printf "task('cipi:extra_artisan', function () {\n%s});\n" "$extra_body")
    else
        h_extra="// no extra artisan (deploy-config)"
        extra_task=""
    fi

    # Write template with line-based placeholders; inject multiline extra-artisan task if any
    local tmp line
    tmp=$(mktemp)
    sed -e "s|__CIPI_APP_USER__|$an|g" \
        -e "s|__CIPI_DEPLOY_PATH__|$dh|g" \
        -e "s|__CIPI_PHP_VERSION__|$v|g" \
        -e "s|__CIPI_REPOSITORY__|$repo_safe|g" \
        -e "s|__CIPI_BRANCH__|$branch_safe|g" \
        -e "s|__CIPI_KEEP_RELEASES__|$kr|g" \
        -e "s|__CIPI_SHARED_FILES__|$shared_files|g" \
        -e "s|__CIPI_HOOK_STORAGE_LINK__|$h_storage|g" \
        -e "s|__CIPI_HOOK_MIGRATE__|$h_migrate|g" \
        -e "s|__CIPI_HOOK_OPTIMIZE__|$h_optimize|g" \
        -e "s|__CIPI_HOOK_HORIZON_TERMINATE__|$h_horizon|g" \
        -e "s|__CIPI_HOOK_QUEUE_RESTART__|$h_queue|g" \
        -e "s|__CIPI_HOOK_EXTRA_ARTISAN__|$h_extra|g" \
        "$tpl" > "$tmp"

    : > "${dh}/.deployer/deploy.php"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == *"__CIPI_EXTRA_ARTISAN_TASK__"* ]]; then
            [[ -n "$extra_task" ]] && printf '%s' "$extra_task" >> "${dh}/.deployer/deploy.php"
        else
            printf '%s\n' "$line" >> "${dh}/.deployer/deploy.php"
        fi
    done < "$tmp"
    rm -f "$tmp"
    chown -R "${an}:${an}" "${dh}/.deployer"
}

# Recreate deploy.php for an existing app (detects type from apps.json)
_create_deployer_config_for_app() {
    local app="$1"
    local repo branch php_ver type
    repo=$(app_get "$app" repository)
    branch=$(app_get "$app" branch)
    php_ver=$(app_get "$app" php)
    if [[ "$(app_get "$app" custom)" == "true" ]]; then type="custom"
    elif [[ -n "$(app_get "$app" octane)" ]]; then type="laravel-octane"
    else type="laravel"
    fi
    _create_deployer_config_from_template "$type" "$app" "$repo" "${branch:-main}" "$php_ver"
    _sync_node_build_script "$app"
}

# Show / edit structured deploy recipe options (apps.json → regenerate deploy.php).
# Usage:
#   cipi app deploy-config <app> [--json]
#   cipi app deploy-config <app> --keep-releases=5 --no-migrate --extra-artisan=view:clear,db:seed
app_deploy_config() {
    local app="${1:-}"; shift || true
    [[ -z "$app" ]] && {
        error "Usage: cipi app deploy-config <app> [--json] [--keep-releases=N] [--migrate|--no-migrate] ..."
        exit 1
    }
    app_exists "$app" || { error "Not found"; exit 1; }
    local is_custom; is_custom=$(app_get "$app" custom)
    [[ "$is_custom" == "true" ]] && { error "Custom apps have no zero-downtime deploy.php recipe"; exit 1; }

    unset ARG_json ARG_keep_releases ARG_migrate ARG_no_migrate ARG_optimize ARG_no_optimize \
        ARG_storage_link ARG_no_storage_link ARG_queue_restart ARG_no_queue_restart \
        ARG_horizon_terminate ARG_no_horizon_terminate ARG_extra_artisan ARG_clear_extra_artisan \
        ARG_node_build ARG_no_node_build ARG_predeploy_snapshot ARG_no_predeploy_snapshot 2>/dev/null || true

    parse_args "$@"
    local want_json=false
    [[ "${ARG_json:-}" == "true" ]] && want_json=true

    local editing=false
    [[ -n "${ARG_keep_releases+x}" || -n "${ARG_migrate+x}" || -n "${ARG_no_migrate+x}" \
        || -n "${ARG_optimize+x}" || -n "${ARG_no_optimize+x}" \
        || -n "${ARG_storage_link+x}" || -n "${ARG_no_storage_link+x}" \
        || -n "${ARG_queue_restart+x}" || -n "${ARG_no_queue_restart+x}" \
        || -n "${ARG_horizon_terminate+x}" || -n "${ARG_no_horizon_terminate+x}" \
        || -n "${ARG_extra_artisan+x}" || -n "${ARG_clear_extra_artisan+x}" \
        || -n "${ARG_node_build+x}" || -n "${ARG_no_node_build+x}" \
        || -n "${ARG_predeploy_snapshot+x}" || -n "${ARG_no_predeploy_snapshot+x}" ]] && editing=true

    if [[ "$editing" == "true" ]]; then
        if [[ -n "${ARG_keep_releases+x}" ]]; then
            [[ "${ARG_keep_releases}" =~ ^[0-9]+$ ]] && (( ARG_keep_releases >= 1 && ARG_keep_releases <= 20 )) \
                || { error "keep-releases must be an integer 1–20"; exit 1; }
            app_set "$app" keep_releases "${ARG_keep_releases}"
        fi
        [[ "${ARG_migrate:-}" == "true" ]] && app_unset "$app" deploy_migrate
        [[ "${ARG_no_migrate:-}" == "true" ]] && app_set "$app" deploy_migrate "false"
        [[ "${ARG_optimize:-}" == "true" ]] && app_unset "$app" deploy_optimize
        [[ "${ARG_no_optimize:-}" == "true" ]] && app_set "$app" deploy_optimize "false"
        [[ "${ARG_storage_link:-}" == "true" ]] && app_unset "$app" deploy_storage_link
        [[ "${ARG_no_storage_link:-}" == "true" ]] && app_set "$app" deploy_storage_link "false"
        [[ "${ARG_queue_restart:-}" == "true" ]] && app_unset "$app" deploy_queue_restart
        [[ "${ARG_no_queue_restart:-}" == "true" ]] && app_set "$app" deploy_queue_restart "false"
        [[ "${ARG_horizon_terminate:-}" == "true" ]] && app_unset "$app" deploy_horizon_terminate
        [[ "${ARG_no_horizon_terminate:-}" == "true" ]] && app_set "$app" deploy_horizon_terminate "false"

        if [[ "${ARG_clear_extra_artisan:-}" == "true" ]]; then
            app_unset "$app" extra_artisan
        elif [[ -n "${ARG_extra_artisan+x}" ]]; then
            local -a arts=()
            local part
            IFS=',' read -ra arts <<< "${ARG_extra_artisan}"
            local -a clean=()
            for part in "${arts[@]}"; do
                part="${part#"${part%%[![:space:]]*}"}"
                part="${part%"${part##*[![:space:]]}"}"
                [[ -z "$part" ]] && continue
                _deploy_cfg_valid_artisan "$part" || { error "Invalid extra artisan: ${part}"; exit 1; }
                clean+=("$part")
            done
            if [[ ${#clean[@]} -eq 0 ]]; then
                app_unset "$app" extra_artisan
            else
                app_set_json "$app" extra_artisan "$(printf '%s\n' "${clean[@]}" | jq -R . | jq -s -c .)"
            fi
        fi

        if [[ -n "${ARG_node_build+x}" || "${ARG_no_node_build:-}" == "true" ]]; then
            if [[ "${ARG_no_node_build:-}" == "true" || -z "${ARG_node_build:-}" ]]; then
                app_unset "$app" node_build
                _sync_node_build_script "$app"
            else
                _validate_node_build_cmd "${ARG_node_build}" || {
                    error "Invalid --node-build command"
                    exit 1
                }
                app_set "$app" node_build "${ARG_node_build}"
                _sync_node_build_script "$app"
            fi
        fi
        [[ "${ARG_predeploy_snapshot:-}" == "true" ]] && app_set "$app" predeploy_snapshot "true"
        [[ "${ARG_no_predeploy_snapshot:-}" == "true" ]] && app_unset "$app" predeploy_snapshot

        _create_deployer_config_for_app "$app"
        log_action "DEPLOY-CONFIG UPDATED: $app"
        success "Deploy config updated for ${app} (deploy.php regenerated)"
    fi

    # Show (always, or after edit)
    local kr nb snap extra b_mig b_opt b_sl b_qr b_ht
    kr=$(_deploy_cfg_keep_releases "$app")
    nb=$(app_get "$app" node_build)
    snap=$(_deploy_cfg_bool "$app" predeploy_snapshot false)
    b_mig=$(_deploy_cfg_bool "$app" deploy_migrate true)
    b_opt=$(_deploy_cfg_bool "$app" deploy_optimize true)
    b_sl=$(_deploy_cfg_bool "$app" deploy_storage_link true)
    b_qr=$(_deploy_cfg_bool "$app" deploy_queue_restart true)
    b_ht=$(_deploy_cfg_bool "$app" deploy_horizon_terminate true)
    extra=$(vault_read apps.json | jq -c --arg a "$app" '.[$a].extra_artisan // []')

    if [[ "$want_json" == "true" ]]; then
        jq -n \
            --arg app "$app" \
            --argjson keep_releases "$kr" \
            --argjson migrate "$b_mig" \
            --argjson optimize "$b_opt" \
            --argjson storage_link "$b_sl" \
            --argjson queue_restart "$b_qr" \
            --argjson horizon_terminate "$b_ht" \
            --argjson predeploy_snapshot "$snap" \
            --arg node_build "${nb:-}" \
            --argjson extra_artisan "$extra" \
            '{
                app: $app,
                keep_releases: $keep_releases,
                migrate: $migrate,
                optimize: $optimize,
                storage_link: $storage_link,
                queue_restart: $queue_restart,
                horizon_terminate: $horizon_terminate,
                predeploy_snapshot: $predeploy_snapshot,
                node_build: (if $node_build == "" then null else $node_build end),
                extra_artisan: $extra_artisan
            }'
        return 0
    fi

    echo -e "\n${BOLD}Deploy config — ${app}${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-20s %s\n" "keep_releases" "$kr"
    printf "  %-20s %s\n" "migrate" "$b_mig"
    printf "  %-20s %s\n" "optimize" "$b_opt"
    printf "  %-20s %s\n" "storage_link" "$b_sl"
    printf "  %-20s %s\n" "queue_restart" "$b_qr"
    printf "  %-20s %s\n" "horizon_terminate" "$b_ht"
    printf "  %-20s %s\n" "predeploy_snapshot" "$snap"
    printf "  %-20s %s\n" "node_build" "${nb:-(none)}"
    printf "  %-20s %s\n" "extra_artisan" "$extra"
    echo ""
}

# ── AUTH ──────────────────────────────────────────────────────

auth_create() {
    local app="${1:-}"; shift || true
    [[ -z "$app" ]] && { error "Usage: cipi auth create <app> [--force]"; exit 1; }
    parse_args "$@"
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    local auth_file="/home/${app}/shared/auth.json"
    if [[ -f "$auth_file" ]]; then
        if [[ "${ARG_force:-}" != "true" ]] && [[ -t 0 ]]; then
            warn "auth.json already exists for '${app}'"
            confirm "Overwrite?" || { info "Cancelled"; return; }
        elif [[ "${ARG_force:-}" != "true" ]] && [[ ! -t 0 ]]; then
            error "auth.json already exists for '${app}' (pass --force to overwrite)"
            exit 1
        fi
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
    cipi_notify \
        "Cipi auth.json created: ${app} on $(hostname)" \
        "Composer auth.json was created.\n\nServer: $(hostname)\nApp: ${app}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        auth_create
    success "auth.json created at ${auth_file}"
    info "Edit it with: cipi auth edit ${app}"
}

auth_edit() {
    local app="${1:-}"; shift || true
    [[ -z "$app" ]] && { error "Usage: cipi auth edit <app> [--file=PATH]"; exit 1; }
    parse_args "$@"
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    local auth_file="/home/${app}/shared/auth.json"
    [[ ! -f "$auth_file" ]] && { error "auth.json not found. Run: cipi auth create ${app}"; exit 1; }

    if [[ -n "${ARG_file:-}" ]]; then
        [[ -f "$ARG_file" ]] || { error "File not found: ${ARG_file}"; exit 1; }
        if ! jq empty "$ARG_file" 2>/dev/null; then
            error "Invalid JSON in ${ARG_file}"
            exit 1
        fi
        jq . "$ARG_file" > "$auth_file"
        chown "${app}:${app}" "$auth_file"; chmod 640 "$auth_file"
        log_action "AUTH EDITED: $app"
        cipi_notify \
            "Cipi auth.json edited: ${app} on $(hostname)" \
            "Composer auth.json was edited.\n\nServer: $(hostname)\nApp: ${app}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
            auth_edit
        success "auth.json updated"
        return 0
    fi

    ${EDITOR:-nano} "$auth_file"
    if jq empty "$auth_file" 2>/dev/null; then
        chown "${app}:${app}" "$auth_file"; chmod 640 "$auth_file"
        log_action "AUTH EDITED: $app"
        cipi_notify \
            "Cipi auth.json edited: ${app} on $(hostname)" \
            "Composer auth.json was edited.\n\nServer: $(hostname)\nApp: ${app}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
            auth_edit
        success "auth.json updated"
    else
        error "Invalid JSON — file saved but may be malformed. Fix it manually: ${auth_file}"
        exit 1
    fi
}

auth_show() {
    local app="${1:-}"; shift || true
    [[ -z "$app" ]] && { error "Usage: cipi auth show <app> [--json]"; exit 1; }
    parse_args "$@"
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    local auth_file="/home/${app}/shared/auth.json"
    [[ ! -f "$auth_file" ]] && { error "auth.json not found. Run: cipi auth create ${app}"; exit 1; }
    if [[ "${ARG_json:-}" == "true" ]]; then
        jq . "$auth_file"
        return 0
    fi
    echo -e "\n${BOLD}auth.json — ${app}${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    jq . "$auth_file" 2>/dev/null || cat "$auth_file"
    echo ""
}

auth_delete() {
    local app="${1:-}"; shift || true
    [[ -z "$app" ]] && { error "Usage: cipi auth delete <app> [--force]"; exit 1; }
    parse_args "$@"
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    local auth_file="/home/${app}/shared/auth.json"
    [[ ! -f "$auth_file" ]] && { error "auth.json not found for '${app}'"; exit 1; }
    if [[ "${ARG_force:-}" != "true" ]] && [[ -t 0 ]]; then
        confirm "Delete auth.json for '${app}'?" || { info "Cancelled"; return; }
    fi
    rm -f "$auth_file"

    if grep -q "auth.json" "/home/${app}/.deployer/deploy.php" 2>/dev/null; then
        sed -i "s|add('shared_files', \['.env', 'auth.json'\]);|add('shared_files', ['.env']);|" "/home/${app}/.deployer/deploy.php"
        info "auth.json removed from Deployer shared_files"
    fi

    log_action "AUTH DELETED: $app"
    cipi_notify \
        "Cipi auth.json deleted: ${app} on $(hostname)" \
        "Composer auth.json was deleted.\n\nServer: $(hostname)\nApp: ${app}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        auth_delete
    success "auth.json deleted for '${app}'"
}

# ── BASIC AUTH (HTTP) ─────────────────────────────────────────
# Adds Nginx HTTP Basic Auth (RFC 7617) in front of an app. State lives in
# apps.json ("basic_auth": "true") and the credentials in an htpasswd file at
# /etc/nginx/cipi-basicauth/<app>.htpasswd; _create_nginx_vhost injects the
# auth_basic directives into the location blocks when enabled. NOTE: this is
# the HTTP gatekeeper — unrelated to `cipi auth` (Composer auth.json).

[[ -z "${BASICAUTH_DIR:-}" ]] && readonly BASICAUTH_DIR="/etc/nginx/cipi-basicauth"

_basicauth_file() { echo "${BASICAUTH_DIR}/${1}.htpasswd"; }

# Reinstall an already-issued Let's Encrypt cert into the (re)generated vhost.
# Uses `certbot install` (no ACME round-trip, so no rate-limit risk) so that
# toggling basic auth never drops HTTPS. Falls back to a plain reload when the
# app has no certificate yet.
_nginx_reapply_ssl() {
    local app="$1" d
    d=$(app_get "$app" domain)
    local cert; cert=$(domain_cert_name "$d")
    if [[ -n "$d" ]] && [[ -d "/etc/letsencrypt/live/${cert}" ]] && command -v certbot &>/dev/null; then
        certbot install --nginx --cert-name "${cert}" --non-interactive --redirect >/dev/null 2>&1 || true
        reload_nginx
    else
        reload_nginx
    fi
}

# Add or replace a single user in the app's htpasswd file. Hash via
# `openssl passwd -apr1` (Apache MD5) so apache2-utils/htpasswd isn't required;
# nginx supports apr1 natively.
_basicauth_set_user() {
    local app="$1" user="$2" password="$3"
    local file; file=$(_basicauth_file "$app")
    # htpasswd lives under /etc/nginx (same root mount as /etc/cipi). Recover
    # remount-ro before mkdir; fail closed so callers never think auth was set.
    if ! _cipi_ensure_config_writable; then
        error "Cannot write credentials: filesystem is read-only (${BASICAUTH_DIR})"
        [[ -n "${_CIPI_REMOUNT_ERR:-}" ]] && error "Remount failed: ${_CIPI_REMOUNT_ERR}"
        error "Try as root: mount -n -o remount,rw / && cipi basicauth enable ${app}"
        error "If remount fails, check disk health: dmesg | tail -30; findmnt /"
        return 1
    fi
    # Same FS as /etc/cipi usually — remount nginx path if probe still fails.
    if ! _cipi_path_writable "$BASICAUTH_DIR"; then
        _cipi_remount_rw /etc/nginx || _cipi_remount_rw / || true
        if ! _cipi_path_writable "$BASICAUTH_DIR"; then
            error "Cannot write credentials: filesystem is read-only (${BASICAUTH_DIR})"
            [[ -n "${_CIPI_REMOUNT_ERR:-}" ]] && error "Remount failed: ${_CIPI_REMOUNT_ERR}"
            return 1
        fi
    fi
    mkdir -p "$BASICAUTH_DIR" || {
        error "Cannot create ${BASICAUTH_DIR}"
        return 1
    }
    chown root:www-data "$BASICAUTH_DIR" 2>/dev/null || true
    chmod 750 "$BASICAUTH_DIR" 2>/dev/null || true
    local hash; hash=$(openssl passwd -apr1 "$password" 2>/dev/null)
    [[ -z "$hash" ]] && { error "Failed to hash password"; return 1; }
    [[ -f "$file" ]] && sed -i "/^${user}:/d" "$file" 2>/dev/null || true
    echo "${user}:${hash}" >> "$file" || {
        error "Cannot write ${file}"
        return 1
    }
    chown root:www-data "$file" 2>/dev/null || true
    chmod 640 "$file" 2>/dev/null || true
    return 0
}

basicauth_enable() {
    local app="${1:-}"; shift || true
    [[ -z "$app" ]] && { error "Usage: cipi basicauth enable <app> [--user=NAME] [--password=PASS]"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    parse_args "$@"

    local user="${ARG_user:-}" password="${ARG_password:-}" generated=false
    if [[ -z "$user" ]]; then
        if [[ -t 0 ]]; then read_input "Username" "admin" user; else user="admin"; fi
    fi
    if [[ ! "$user" =~ ^[A-Za-z0-9._-]+$ ]]; then
        error "Invalid username. Use letters, digits, dot, underscore, hyphen."; exit 1
    fi
    if [[ -z "$password" ]]; then
        if [[ -t 0 ]]; then
            local p1 p2
            echo -e -n "${CYAN}Password (empty = generate)${NC}: "; read -rs p1; echo ""
            if [[ -z "$p1" ]]; then
                password=$(generate_password 24); generated=true
            else
                echo -e -n "${CYAN}Confirm password${NC}: "; read -rs p2; echo ""
                [[ "$p1" != "$p2" ]] && { error "Passwords do not match"; exit 1; }
                password="$p1"
            fi
        else
            password=$(generate_password 24); generated=true
        fi
    fi

    step "Writing credentials..."
    _basicauth_set_user "$app" "$user" "$password" || exit 1
    app_set "$app" basic_auth "true"
    success "User '${user}' added"

    step "Updating Nginx vhost..."
    _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)"
    _nginx_reapply_ssl "$app"
    success "Basic auth enabled"

    log_action "BASICAUTH ENABLED: $app user=$user"
    cipi_notify \
        "Cipi basic auth enabled: ${app} on $(hostname)" \
        "HTTP basic auth was enabled.\n\nServer: $(hostname)\nApp: ${app}\nDomain: $(app_get "$app" domain)\nUser: ${user}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        basicauth_enable

    echo ""
    echo -e "  ${BOLD}Basic auth${NC}  ${GREEN}enabled${NC} for ${CYAN}$(app_get "$app" domain)${NC}"
    echo -e "  ${BOLD}User${NC}        ${CYAN}${user}${NC}"
    if [[ "$generated" == true ]]; then
        echo -e "  ${BOLD}Password${NC}    ${CYAN}${password}${NC}"
        echo -e "  ${YELLOW}${BOLD}⚠ SAVE THIS PASSWORD — shown only once${NC}"
    fi
    echo ""
}

basicauth_disable() {
    local app="${1:-}"
    [[ -z "$app" ]] && { error "Usage: cipi basicauth disable <app>"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }

    # Treat the htpasswd file as the source of truth alongside the flag: if an
    # earlier op (app edit / re-sync) reset basic_auth in apps.json without
    # regenerating the vhost, Nginx keeps enforcing the old auth_basic block and
    # the file lingers. Disabling on flag alone would then leave the app stuck
    # protected with no way to turn it off, so also disable when the file exists.
    local file; file=$(_basicauth_file "$app")
    if [[ "$(app_get "$app" basic_auth)" != "true" ]] && [[ ! -f "$file" ]]; then
        info "Basic auth is not enabled for '${app}'"; return
    fi

    app_set "$app" basic_auth "false"
    rm -f "$file"

    step "Updating Nginx vhost..."
    _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)"
    _nginx_reapply_ssl "$app"
    success "Basic auth disabled for '${app}'"

    log_action "BASICAUTH DISABLED: $app"
    cipi_notify \
        "Cipi basic auth disabled: ${app} on $(hostname)" \
        "HTTP basic auth was disabled.\n\nServer: $(hostname)\nApp: ${app}\nDomain: $(app_get "$app" domain)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        basicauth_disable
}

basicauth_status() {
    local app="${1:-}"
    [[ -z "$app" ]] && { error "Usage: cipi basicauth status <app>"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    local enabled; enabled=$(app_get "$app" basic_auth)
    local file; file=$(_basicauth_file "$app")
    echo -e "\n${BOLD}Basic auth — ${app}${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ "$enabled" == "true" ]]; then
        printf "  %-10s ${GREEN}%s${NC}\n" "Status" "enabled"
    else
        printf "  %-10s ${DIM}%s${NC}\n" "Status" "disabled"
    fi
    if [[ -f "$file" ]]; then
        printf "  %-10s ${CYAN}%s${NC}\n" "Users" "$(cut -d: -f1 "$file" | paste -sd, -)"
    fi
    echo ""
}

basicauth_command() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        enable)  basicauth_enable "$@" ;;
        disable) basicauth_disable "$@" ;;
        status)  basicauth_status "$@" ;;
        *) error "Unknown: $sub"; echo "Use: enable disable status"; exit 1 ;;
    esac
}

# ── SUSPEND / UNSUSPEND ───────────────────────────────────────

app_suspend() {
    local app="${1:-}"
    [[ -z "$app" ]] && { error "Usage: cipi app suspend <app>"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }

    if [[ "$(app_get "$app" suspended)" == "true" ]]; then
        info "App '${app}' is already suspended"; return
    fi

    app_set "$app" suspended "true"

    step "Building suspension page..."
    _ensure_suspended_page

    step "Updating Nginx vhost..."
    _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)"
    _nginx_reapply_ssl "$app"
    success "App '${app}' suspended — serving offline page (HTTP 503)"

    log_action "APP SUSPENDED: $app"
    cipi_notify \
        "Cipi app suspended: ${app} on $(hostname)" \
        "An app was suspended and is now serving the offline page.\n\nServer: $(hostname)\nApp: ${app}\nDomain: $(app_get "$app" domain)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        app_suspend

    echo ""
    echo -e "  ${BOLD}Status${NC}  ${YELLOW}suspended${NC} for ${CYAN}$(app_get "$app" domain)${NC}"
    echo -e "  ${DIM}Restore with: cipi app unsuspend ${app}${NC}"
    echo ""
}

app_unsuspend() {
    local app="${1:-}"
    [[ -z "$app" ]] && { error "Usage: cipi app unsuspend <app>"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }

    if [[ "$(app_get "$app" suspended)" != "true" ]]; then
        info "App '${app}' is not suspended"; return
    fi

    app_set "$app" suspended "false"

    step "Restoring Nginx vhost..."
    _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)"
    _nginx_reapply_ssl "$app"
    success "App '${app}' is back online"

    log_action "APP UNSUSPENDED: $app"
    cipi_notify \
        "Cipi app unsuspended: ${app} on $(hostname)" \
        "An app was unsuspended and is back online.\n\nServer: $(hostname)\nApp: ${app}\nDomain: $(app_get "$app" domain)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        app_unsuspend
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
        "The SSH password for app '${app}' was regenerated.\n\nServer: $(hostname)\nApp: ${app}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        app_ssh_password_reset

    echo ""
    echo -e "${GREEN}✓${NC} New SSH password for '${app}': ${CYAN}${new_pass}${NC}"
    echo -e "${YELLOW}${BOLD}⚠ SAVE THIS PASSWORD — shown only once${NC}"
    echo ""
}

app_reset_db_password() {
    local app="${1:-}"; [[ -z "$app" ]] && { error "Usage: cipi app reset-db-password <app>"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    local is_custom; is_custom=$(app_get "$app" custom)
    [[ "$is_custom" == "true" ]] && { error "Custom apps have no database"; exit 1; }

    # shellcheck source=/dev/null
    source "${CIPI_LIB}/db.sh"
    local eng new_pass
    eng=$(app_get "$app" engine); [[ -z "$eng" ]] && eng="mariadb"
    eng=$(db_require_engine "$eng") || exit 1

    new_pass=$(generate_password 40)
    db_change_user_password "$eng" "$app" "$new_pass" || { error "Password change failed"; exit 1; }

    local env_file="/home/${app}/shared/.env"
    [[ -f "$env_file" ]] || { warn ".env not found"; return; }
    sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${new_pass}|" "$env_file"
    chown "${app}:${app}" "$env_file"
    chmod 640 "$env_file"
    info ".env updated with new DB password"

    log_action "APP DB PASSWORD RESET: $app"

    cipi_notify \
        "Cipi app DB password reset: ${app} on $(hostname)" \
        "The database password for app '${app}' was regenerated.\n\nServer: $(hostname)\nApp: ${app}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        app_db_password_reset

    echo ""
    echo -e "${GREEN}✓${NC} New DB password for '${app}': ${CYAN}${new_pass}${NC}"
    echo -e "${YELLOW}${BOLD}⚠ SAVE THIS PASSWORD — shown only once${NC}"
    echo ""
}

# ── CONVERT FPM ↔ Octane ──────────────────────────────────────

_reapply_ssl_if_present() {
    local app="$1" d
    d=$(app_get "$app" domain)
    local cert; cert=$(domain_cert_name "$d")
    [[ -n "$d" && -d "/etc/letsencrypt/live/${cert}" ]] || return 0
    certbot install --nginx --cert-name "$cert" --non-interactive --redirect 2>&1 || true
    if nginx -t &>/dev/null; then
        systemctl reload nginx 2>/dev/null || true
    fi
}

_env_set_or_add() {
    local file="$1" key="$2" val="$3"
    [[ -f "$file" ]] || return 0
    if grep -qE "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$file"
    else
        printf '\n%s=%s\n' "$key" "$val" >> "$file"
    fi
}

# Write a group of KEY=VALUE pairs into an .env.
#
# Keys already in the file are updated in place; the ones that are missing are
# appended together under a single comment header, instead of each arriving
# with its own leading blank line the way _env_set_or_add leaves them — which
# turns twelve new Reverb keys into twelve stanzas.
#
# `fill` = true keeps any existing non-empty value: used where Cipi derives a
# value the application may legitimately have set for itself.
_env_apply_group() {
    local file="$1" fill="$2" header="$3"; shift 3
    [[ -f "$file" ]] || return 0
    local -a missing=()
    local pair key val cur
    for pair in "$@"; do
        key="${pair%%=*}"; val="${pair#*=}"
        if grep -qE "^${key}=" "$file" 2>/dev/null; then
            if [[ "$fill" == "true" ]]; then
                cur=$(_env_read_key "$file" "$key" 2>/dev/null || true)
                [[ -n "$cur" ]] && continue
            fi
            sed -i "s|^${key}=.*|${key}=${val}|" "$file"
        else
            missing+=("${key}=${val}")
        fi
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    {
        printf '\n'
        if [[ -n "$header" ]] && ! grep -qxF "# ${header}" "$file"; then
            printf '# %s\n' "$header"
        fi
        printf '%s\n' "${missing[@]}"
    } >> "$file"
    return 0
}

_env_remove_keys() {
    local file="$1"; shift
    [[ -f "$file" ]] || return 0
    local k
    for k in "$@"; do
        sed -i "/^${k}=/d" "$file" 2>/dev/null || true
    done
}

app_convert() {
    local app="${1:-}"; shift || true
    [[ -z "$app" ]] && { error "Usage: cipi app convert <app> --to=octane|fpm"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    parse_args "$@"
    local to="${ARG_to:-}"
    [[ -z "$to" && "${ARG_octane:-}" == "true" ]] && to="octane"
    [[ -z "$to" && "${ARG_no_octane:-}" == "true" ]] && to="fpm"
    [[ -z "$to" ]] && { error "Usage: cipi app convert <app> --to=octane|fpm"; exit 1; }

    [[ "$(app_get "$app" custom)" == "true" ]] && {
        error "Octane convert is only available for Laravel apps (not custom)"
        exit 1
    }

    local php_ver domain cur_octane
    php_ver=$(app_get "$app" php)
    domain=$(app_get "$app" domain)
    cur_octane=$(app_get "$app" octane)
    local envf="/home/${app}/shared/.env"
    local conf="/etc/supervisor/conf.d/${app}.conf"
    [[ -f "$conf" ]] || echo "" > "$conf"

    case "$to" in
        octane|frankenphp)
            if [[ -n "$cur_octane" ]]; then
                info "App '${app}' is already on Octane (${cur_octane})"
                return 0
            fi
            local port
            port=$(_octane_allocate_port) || { error "No free Octane port in 8100–8999"; exit 1; }
            step "Converting '${app}' → Octane (FrankenPHP) :${port}..."
            app_set "$app" octane "frankenphp"
            app_set "$app" octane_port "$port"
            rm -f "/etc/php/${php_ver}/fpm/pool.d/${app}.conf"
            reload_php_fpm "$php_ver" 2>/dev/null || true
            _supervisor_remove_program "$app" "${app}-octane"
            _create_supervisor_octane "$app" "$php_ver" "$port"
            reload_supervisor
            _ensure_nginx_octane_map
            _create_nginx_vhost "$app" "$domain" "$php_ver"
            reload_nginx || exit 1
            _reapply_ssl_if_present "$app"
            _env_set_or_add "$envf" "OCTANE_SERVER" "frankenphp"
            _env_set_or_add "$envf" "OCTANE_HTTPS" "true"
            chown "${app}:${app}" "$envf" 2>/dev/null || true
            _create_deployer_config_for_app "$app"
            log_action "APP CONVERT: $app → octane port=$port"
            success "Converted to Octane (FrankenPHP) on 127.0.0.1:${port}"
            info "Ensure the app has laravel/octane + octane:install --server=frankenphp, then: cipi deploy ${app}"
            ;;
        fpm|php-fpm|phpfpm)
            if [[ -z "$cur_octane" ]]; then
                info "App '${app}' is already on PHP-FPM"
                return 0
            fi
            step "Converting '${app}' → PHP-FPM..."
            supervisorctl stop "${app}-octane" 2>/dev/null || true
            _supervisor_remove_program "$app" "${app}-octane"
            reload_supervisor
            app_unset "$app" octane
            app_unset "$app" octane_port
            _create_fpm_pool "$app" "$php_ver"
            reload_php_fpm "$php_ver" || exit 1
            _create_nginx_vhost "$app" "$domain" "$php_ver"
            reload_nginx || exit 1
            _reapply_ssl_if_present "$app"
            _env_remove_keys "$envf" OCTANE_SERVER OCTANE_HTTPS
            chown "${app}:${app}" "$envf" 2>/dev/null || true
            _create_deployer_config_for_app "$app"
            log_action "APP CONVERT: $app → fpm"
            success "Converted to PHP-FPM"
            ;;
        *)
            error "Invalid --to value. Use: octane|fpm"
            exit 1
            ;;
    esac
}

# ── REVERB ────────────────────────────────────────────────────

app_reverb() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        enable)  _app_reverb_enable "$@" ;;
        disable) _app_reverb_disable "$@" ;;
        status)  _app_reverb_status "$@" ;;
        *) error "Usage: cipi app reverb enable|disable|status <app>"
           echo "      enable [--restart-supervisor]  apply the new open-file limit now"; exit 1 ;;
    esac
}

# Write the .env half of a Reverb setup: credentials, the localhost socket the
# supervisor program binds to, and the public host/port/scheme that both the
# PHP broadcaster and the frontend bundle dial.
#
# Credentials are generated once and then left alone. Rotating them would
# disconnect every live client and invalidate a frontend bundle already built
# against the old key, so an existing non-empty value always wins — which also
# means an app that arrived with its own Reverb credentials keeps them.
#
# The public side is derived from what the server actually serves rather than
# assumed: https/443 once a certificate exists, http/80 before that, and a
# concrete host when the app sits on a wildcard domain (no browser can open a
# socket to "*.example.com"). Re-derived after `cipi ssl install` and after a
# domain change, so these values never drift away from nginx.
#
# `--fill` writes only what is missing. The migration uses it so that an app
# whose .env was tuned by hand — a dedicated socket host, a scheme behind an
# upstream proxy — keeps what it had and only gains the keys it lacked.
_reverb_sync_env() {
    local app="$1" fill="false"
    [[ "${2:-}" == "--fill" ]] && fill="true"
    local envf="/home/${app}/shared/.env"
    [[ -f "$envf" ]] || return 0
    local port; port=$(app_get "$app" reverb_port)
    [[ -n "$port" ]] || return 0

    local domain host scheme pub_port
    domain=$(app_get "$app" domain)
    host=$(domain_url_host "$domain")
    scheme="http"; pub_port="80"
    if [[ -d "/etc/letsencrypt/live/$(domain_cert_name "$domain")" ]]; then
        scheme="https"; pub_port="443"
    fi

    local rid rkey rsecret
    rid=$(_env_read_key "$envf" REVERB_APP_ID 2>/dev/null || true)
    rkey=$(_env_read_key "$envf" REVERB_APP_KEY 2>/dev/null || true)
    rsecret=$(_env_read_key "$envf" REVERB_APP_SECRET 2>/dev/null || true)
    [[ -n "$rid" ]]     || rid=$(( ($(od -An -N4 -tu4 /dev/urandom | tr -d ' ') % 900000) + 100000 ))
    [[ -n "$rkey" ]]    || rkey=$(openssl rand -hex 10)
    [[ -n "$rsecret" ]] || rsecret=$(openssl rand -hex 16)

    local hdr="Laravel Reverb — managed by Cipi (cipi app reverb status ${app})"

    # Where the supervisor program listens. Cipi owns this pair outright — the
    # port is the one it allocated and wrote into the Supervisor program — so
    # it is written even in fill mode.
    _env_apply_group "$envf" false "$hdr" \
        "REVERB_SERVER_HOST=127.0.0.1" \
        "REVERB_SERVER_PORT=${port}"

    _env_apply_group "$envf" "$fill" "$hdr" \
        "BROADCAST_CONNECTION=reverb" \
        "REVERB_APP_ID=${rid}" \
        "REVERB_APP_KEY=${rkey}" \
        "REVERB_APP_SECRET=${rsecret}" \
        "REVERB_HOST=${host}" \
        "REVERB_PORT=${pub_port}" \
        "REVERB_SCHEME=${scheme}" \
        "VITE_REVERB_APP_KEY=${rkey}" \
        "VITE_REVERB_HOST=${host}" \
        "VITE_REVERB_PORT=${pub_port}" \
        "VITE_REVERB_SCHEME=${scheme}"

    chown "${app}:${app}" "$envf" 2>/dev/null || true
}

# Raise the file-descriptor ceilings a WebSocket server runs into, and say what
# is still needed. Supervisor picks its new limit up only on a restart — which
# stops every queue worker on the box, so it is the admin's call, not ours.
_reverb_ensure_capacity() {
    local restart="${1:-false}" rc=0
    _ensure_nginx_ws_limits || rc=$?
    case "$rc" in
        2)  # A raised worker_rlimit_nofile only reaches the workers a reload
            # spawns, so the reload is part of applying it.
            systemctl reload nginx 2>/dev/null || true
            info "nginx raised to ${CIPI_WS_NOFILE} open files / ${CIPI_WS_WORKER_CONNECTIONS} connections per worker" ;;
        1)  warn "Could not raise nginx's worker limits — nginx.conf was left unchanged (check: nginx -t)" ;;
    esac
    if _ensure_supervisor_fd_limit; then
        return 0
    fi
    if [[ "$restart" == "true" ]]; then
        step "Restarting Supervisor to apply the new file-descriptor limit..."
        if systemctl restart supervisor 2>/dev/null; then
            success "Supervisor restarted (${CIPI_WS_NOFILE} open files)"
        else
            warn "systemctl restart supervisor failed — check: systemctl status supervisor"
        fi
        return 0
    fi
    echo ""
    warn "Supervisor is still running with the default limit of open files."
    echo -e "  ${DIM}Reverb gets one file descriptor per connected client, so it will stop"
    echo -e "  accepting clients at around a thousand. The new limit (${CIPI_WS_NOFILE}) is"
    echo -e "  configured and applies on the next Supervisor restart, which also"
    echo -e "  restarts every queue worker on this server:${NC}"
    echo -e "      ${CYAN}systemctl restart supervisor${NC}"
    echo -e "  ${DIM}or re-run this command with ${NC}--restart-supervisor${DIM} to do it now.${NC}"
}

_app_reverb_enable() {
    local app="${1:-}"; shift || true
    [[ -z "$app" ]] && { error "Usage: cipi app reverb enable <app> [--restart-supervisor]"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    [[ "$(app_get "$app" custom)" == "true" ]] && { error "Reverb is only for Laravel apps"; exit 1; }
    parse_args "$@"
    local restart="${ARG_restart_supervisor:-false}"

    if [[ -n "$(app_get "$app" reverb)" ]]; then
        info "Reverb already enabled for '${app}' (port $(app_get "$app" reverb_port))"
        # Converge anyway: a certificate or a domain change since the last
        # enable moves REVERB_HOST/PORT/SCHEME, and a missing credential is
        # exactly what stops reverb:start from booting.
        _reverb_sync_env "$app"
        _reverb_ensure_capacity "$restart"
        return 0
    fi
    local port php_ver domain
    port=$(_reverb_allocate_port) || { error "No free Reverb port in 9000–9099"; exit 1; }
    php_ver=$(app_get "$app" php)
    domain=$(app_get "$app" domain)
    step "Enabling Reverb for '${app}' :${port}..."

    # Remember what the app was broadcasting through, so disabling Reverb puts
    # it back instead of leaving BROADCAST_CONNECTION pointed at a dead server.
    local envf="/home/${app}/shared/.env" prev_broadcast=""
    if [[ -f "$envf" ]]; then
        prev_broadcast=$(_env_read_key "$envf" BROADCAST_CONNECTION 2>/dev/null || true)
    fi
    if [[ -n "$prev_broadcast" && "$prev_broadcast" != "reverb" ]]; then
        app_set "$app" reverb_prev_broadcast "$prev_broadcast"
    fi

    app_set "$app" reverb "true"
    app_set "$app" reverb_port "$port"
    local conf="/etc/supervisor/conf.d/${app}.conf"
    [[ -f "$conf" ]] || echo "" > "$conf"
    _supervisor_remove_program "$app" "${app}-reverb"
    _create_supervisor_reverb "$app" "$php_ver" "$port"
    reload_supervisor
    _create_nginx_vhost "$app" "$domain" "$php_ver"
    reload_nginx || exit 1
    _reapply_ssl_if_present "$app"
    _reverb_sync_env "$app"

    log_action "REVERB ENABLE: $app port=$port"
    success "Reverb enabled on 127.0.0.1:${port}"
    echo -e "  ${DIM}nginx proxies ${NC}/app/{key}${DIM} (WebSocket) and ${NC}/apps/{id}/…${DIM} (broadcast API)"
    echo -e "  to it — an app with its own /app or /apps route cannot share the domain.${NC}"
    if domain_is_wildcard "$domain"; then
        warn "'${domain}' is a wildcard: REVERB_HOST was set to $(domain_url_host "$domain")"
        echo -e "  ${DIM}A multi-tenant frontend has to pick its own host at runtime.${NC}"
    fi
    if [[ ! -d "/etc/letsencrypt/live/$(domain_cert_name "$domain")" ]]; then
        echo -e "  ${DIM}No certificate yet, so REVERB_SCHEME is ${NC}http${DIM} on port 80."
        echo -e "  ${CYAN}cipi ssl install ${app}${NC}${DIM} switches it to wss:// automatically.${NC}"
    fi
    _reverb_ensure_capacity "$restart"
    echo ""
    info "Require laravel/reverb in the app, then: cipi deploy ${app}"
}

_app_reverb_disable() {
    local app="${1:-}"
    [[ -z "$app" ]] && { error "Usage: cipi app reverb disable <app>"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    [[ -z "$(app_get "$app" reverb)" ]] && { info "Reverb already disabled for '${app}'"; return 0; }
    local php_ver domain
    php_ver=$(app_get "$app" php)
    domain=$(app_get "$app" domain)
    step "Disabling Reverb for '${app}'..."
    supervisorctl stop "${app}-reverb" 2>/dev/null || true
    _supervisor_remove_program "$app" "${app}-reverb"
    reload_supervisor
    app_unset "$app" reverb
    app_unset "$app" reverb_port
    _create_nginx_vhost "$app" "$domain" "$php_ver"
    reload_nginx || exit 1
    _reapply_ssl_if_present "$app"

    # Point broadcasting back where it was before Reverb took it over. Leaving
    # BROADCAST_CONNECTION=reverb behind would have every broadcast fail
    # against a server that is no longer running.
    local envf="/home/${app}/shared/.env" prev
    prev=$(app_get "$app" reverb_prev_broadcast)
    [[ -n "$prev" ]] || prev="log"
    _env_set_or_add "$envf" "BROADCAST_CONNECTION" "$prev"
    app_unset "$app" reverb_prev_broadcast
    # Only the two keys Cipi owns are dropped. The credentials stay: they are
    # what a re-enable — or a frontend bundle already built — depends on.
    _env_remove_keys "$envf" REVERB_SERVER_HOST REVERB_SERVER_PORT
    log_action "REVERB DISABLE: $app"
    success "Reverb disabled for '${app}' (broadcasting back to '${prev}')"
}

_app_reverb_status() {
    local app="${1:-}"
    [[ -z "$app" ]] && { error "Usage: cipi app reverb status <app>"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    local r p
    r=$(app_get "$app" reverb)
    p=$(app_get "$app" reverb_port)
    if [[ -z "$r" ]]; then
        echo -e "  Reverb: ${DIM}disabled${NC}"
        return 0
    fi
    echo -e "  Reverb: ${GREEN}enabled${NC} 127.0.0.1:${p}"
    supervisorctl status "${app}-reverb" 2>/dev/null || true

    local envf="/home/${app}/shared/.env"
    if [[ -f "$envf" ]]; then
        local host scheme pub_port key missing=""
        host=$(_env_read_key "$envf" REVERB_HOST 2>/dev/null || true)
        scheme=$(_env_read_key "$envf" REVERB_SCHEME 2>/dev/null || true)
        pub_port=$(_env_read_key "$envf" REVERB_PORT 2>/dev/null || true)
        key=$(_env_read_key "$envf" REVERB_APP_KEY 2>/dev/null || true)
        if [[ -n "$host" ]]; then
            local ws="ws"; [[ "$scheme" == "https" ]] && ws="wss"
            echo -e "  Clients dial: ${CYAN}${ws}://${host}:${pub_port:-443}/app/${key}${NC}"
        fi
        # A key that is present but empty is the state Laravel's own .env
        # stanza ships in, and it is just as fatal as a missing one — so test
        # the value, not whether the line exists.
        local k v
        for k in REVERB_APP_ID REVERB_APP_KEY REVERB_APP_SECRET; do
            v=$(_env_read_key "$envf" "$k" 2>/dev/null || true)
            [[ -n "$v" ]] || missing="${missing} ${k}"
        done
        if [[ -n "$missing" ]]; then
            warn "Missing in .env:${missing} — run: cipi app reverb enable ${app}"
        fi
        # A certificate added after Reverb was enabled leaves the .env on ws://
        # while nginx already serves wss:// — the browser then blocks the
        # connection as mixed content, with nothing in the Reverb log.
        local dom; dom=$(app_get "$app" domain)
        if [[ -d "/etc/letsencrypt/live/$(domain_cert_name "$dom")" && "$scheme" != "https" ]]; then
            warn "This app has a certificate but REVERB_SCHEME is '${scheme:-unset}'"
            echo -e "  ${DIM}Re-run ${NC}cipi app reverb enable ${app}${DIM} to move it to wss://.${NC}"
        fi
    fi

    if _supervisor_fd_limit_active; then
        echo -e "  Open files: ${GREEN}${CIPI_WS_NOFILE}${NC} ${DIM}(supervisor)${NC}"
    else
        warn "Supervisor still runs with the default open-file limit (~1000 clients)"
        echo -e "  ${DIM}Apply it with: ${NC}systemctl restart supervisor${NC}"
    fi
}

# ── SCHEDULE ──────────────────────────────────────────────────

schedule_command() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        status|on|off) _schedule_set "$sub" "$@" ;;
        *) error "Usage: cipi schedule status|on|off <app>"; exit 1 ;;
    esac
}

_schedule_crontab_write() {
    local app="$1" php_ver="$2" schedule_on="$3"
    local home="/home/${app}"
    local schedule_line=""
    if [[ "$schedule_on" == "on" ]]; then
        schedule_line="# Laravel Scheduler
* * * * * /usr/bin/php${php_ver} ${home}/current/artisan schedule:run >> /dev/null 2>&1
"
    else
        schedule_line="# Laravel Scheduler (disabled by cipi schedule off)
"
    fi
    cat <<CRON | crontab -u "$app" -
${schedule_line}# Cipi deploy trigger (written by cipi/agent webhook)
* * * * * test -f ${home}/.deploy-trigger && rm -f ${home}/.deploy-trigger && /usr/local/bin/cipi-app-deploy ${app} ${php_ver} webhook >/dev/null 2>&1
CRON
}

_schedule_set() {
    local mode="$1" app="${2:-}"
    [[ -z "$app" ]] && { error "Usage: cipi schedule ${mode} <app>"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    [[ "$(app_get "$app" custom)" == "true" ]] && { error "Scheduler is only for Laravel apps"; exit 1; }
    local php_ver cur
    php_ver=$(app_get "$app" php)
    cur=$(app_get "$app" schedule)
    [[ -z "$cur" ]] && cur="on"

    if [[ "$mode" == "status" ]]; then
        local cron_has="no"
        crontab -u "$app" -l 2>/dev/null | grep -q 'schedule:run' && cron_has="yes"
        echo -e "  Schedule: ${CYAN}${cur}${NC}  (crontab schedule:run: ${cron_has})"
        return 0
    fi

    _schedule_crontab_write "$app" "$php_ver" "$mode"
    app_set "$app" schedule "$mode"
    log_action "SCHEDULE ${mode}: $app"
    success "Scheduler ${mode} for '${app}'"
}

# ── LIMITS ────────────────────────────────────────────────────

app_limits() {
    local app="${1:-}"; shift || true
    [[ -z "$app" ]] && { error "Usage: cipi app limits <app> [--fpm-max-children=N] [--memory-limit=256M] [--octane-workers=N] [--worker-procs=N]"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    parse_args "$@"

    local changed=false
    local limits
    limits=$(vault_read apps.json | jq -c --arg a "$app" '.[$a].limits // {}')

    if [[ -n "${ARG_fpm_max_children:-}" ]]; then
        [[ "${ARG_fpm_max_children}" =~ ^[0-9]+$ ]] || { error "--fpm-max-children must be a number"; exit 1; }
        (( ARG_fpm_max_children > 50 )) && ARG_fpm_max_children=50
        (( ARG_fpm_max_children < 1 )) && ARG_fpm_max_children=1
        limits=$(echo "$limits" | jq -c --argjson n "${ARG_fpm_max_children}" '.fpm_max_children = $n')
        changed=true
    fi
    if [[ -n "${ARG_memory_limit:-}" ]]; then
        [[ "${ARG_memory_limit}" =~ ^[0-9]+[MmGg]?$ ]] || { error "Invalid --memory-limit"; exit 1; }
        limits=$(echo "$limits" | jq -c --arg v "${ARG_memory_limit}" '.memory_limit = $v')
        changed=true
    fi
    if [[ -n "${ARG_octane_workers:-}" ]]; then
        [[ "${ARG_octane_workers}" =~ ^[0-9]+$ ]] || { error "--octane-workers must be a number"; exit 1; }
        (( ARG_octane_workers > 16 )) && ARG_octane_workers=16
        (( ARG_octane_workers < 1 )) && ARG_octane_workers=1
        limits=$(echo "$limits" | jq -c --argjson n "${ARG_octane_workers}" '.octane_workers = $n')
        changed=true
    fi
    if [[ -n "${ARG_worker_procs:-}" ]]; then
        [[ "${ARG_worker_procs}" =~ ^[0-9]+$ ]] || { error "--worker-procs must be a number"; exit 1; }
        (( ARG_worker_procs > 20 )) && ARG_worker_procs=20
        (( ARG_worker_procs < 1 )) && ARG_worker_procs=1
        limits=$(echo "$limits" | jq -c --argjson n "${ARG_worker_procs}" '.worker_procs = $n')
        changed=true
    fi

    if [[ "$changed" == false ]]; then
        echo -e "\n${BOLD}Limits — ${app}${NC}"
        echo "$limits" | jq -r 'to_entries[] | "  \(.key): \(.value)"' 2>/dev/null || echo "  (defaults)"
        echo -e "  ${DIM}fpm_max_children default 5 (max 50)${NC}"
        echo -e "  ${DIM}memory_limit default 256M${NC}"
        echo -e "  ${DIM}octane_workers default 2 (max 16)${NC}"
        echo -e "  ${DIM}worker_procs default 1 (max 20)${NC}"
        echo ""
        return 0
    fi

    app_set_json "$app" limits "$limits"
    local php_ver domain
    php_ver=$(app_get "$app" php)
    domain=$(app_get "$app" domain)

    if [[ -z "$(app_get "$app" octane)" ]]; then
        _create_fpm_pool "$app" "$php_ver"
        reload_php_fpm "$php_ver" || true
    fi

    # Rebuild octane / default worker procs when relevant
    if [[ -n "$(app_get "$app" octane)" ]]; then
        local port; port=$(app_get "$app" octane_port)
        supervisorctl stop "${app}-octane" 2>/dev/null || true
        _supervisor_remove_program "$app" "${app}-octane"
        _create_supervisor_octane "$app" "$php_ver" "$port"
    fi
    if [[ "$(app_get "$app" horizon)" != "true" ]] && grep -q "\[program:${app}-worker-default\]" "/etc/supervisor/conf.d/${app}.conf" 2>/dev/null; then
        supervisorctl stop "${app}-worker-default:"* 2>/dev/null || true
        _supervisor_remove_program "$app" "${app}-worker-default"
        _create_supervisor_worker "$app" "$php_ver" "default"
    fi
    reload_supervisor
    log_action "APP LIMITS: $app $limits"
    success "Limits updated for '${app}'"
}

# ── CLONE / STAGING ───────────────────────────────────────────

app_clone() {
    local src="${1:-}"; shift || true
    [[ -z "$src" ]] && { error "Usage: cipi app clone <src> --domain=D [--name=] [--branch=] [--with-db|--no-db]"; exit 1; }
    app_exists "$src" || { error "Source app '$src' not found"; exit 1; }
    parse_args "$@"

    local domain="${ARG_domain:-}"
    [[ -z "$domain" ]] && { error "--domain is required"; exit 1; }
    validate_domain_or_wildcard "$domain" || { error "Invalid domain '${domain}'"; exit 1; }
    domain_is_used_by_other_app "$domain" && { error "Domain '${domain}' is already used by app '${DOMAIN_USED_BY_APP}'"; exit 1; }

    local name="${ARG_name:-}"
    if [[ -z "$name" ]]; then
        name=$(echo "$domain" | sed 's/[^a-z0-9]//g' | cut -c1-16)
        [[ ${#name} -lt 3 ]] && name="stg${RANDOM}"
    fi
    validate_username "$name" || { error "Invalid username '${name}'"; exit 1; }
    app_exists "$name" && { error "App '${name}' already exists"; exit 1; }
    id "$name" &>/dev/null && { error "User '${name}' already exists"; exit 1; }

    [[ "$(app_get "$src" custom)" == "true" ]] && { error "Cloning custom apps is not supported"; exit 1; }

    local branch php_ver engine repo with_db="true"
    branch="${ARG_branch:-$(app_get "$src" branch)}"
    php_ver=$(app_get "$src" php)
    engine=$(app_get "$src" engine); [[ -z "$engine" ]] && engine="mariadb"
    repo=$(app_get "$src" repository)
    [[ "${ARG_no_db:-}" == "true" ]] && with_db="false"
    [[ "${ARG_with_db:-}" == "true" ]] && with_db="true"

    local create_args=(--user="$name" --domain="$domain" --repository="$repo" --branch="$branch" --php="$php_ver" --engine="$engine")
    if [[ -n "$(app_get "$src" octane)" ]]; then
        create_args+=(--octane=frankenphp)
    fi

    info "Cloning '${src}' → '${name}' (${domain})..."
    app_create "${create_args[@]}"

    app_set "$name" cloned_from "$src"

    # Copy non-secret env keys from source (keep new APP_KEY / DB_* / CIPI_*)
    local src_env="/home/${src}/shared/.env"
    local dst_env="/home/${name}/shared/.env"
    if [[ -f "$src_env" && -f "$dst_env" ]]; then
        local line key
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
            key="${line%%=*}"
            case "$key" in
                # REVERB_*/VITE_REVERB_* are deliberately not carried over: the
                # clone gets its own port, its own credentials and its own
                # domain below. Copying them would point a staging clone's
                # frontend at the production socket and hand it the production
                # app secret.
                #
                # MEILISEARCH_*/SCOUT_PREFIX are excluded for a sharper reason:
                # the source's key is scoped to the source's index prefix, so a
                # clone that inherited it would not fail — it would reindex
                # straight into production's indexes. The clone gets its own
                # key and prefix below.
                APP_KEY|APP_URL|DB_*|DATABASE_URL|CIPI_*|OCTANE_*|REVERB_*|VITE_REVERB_*) continue ;;
                MEILISEARCH_*|SCOUT_PREFIX) continue ;;
            esac
            _env_set_or_add "$dst_env" "$key" "${line#*=}"
        done < "$src_env"
        _env_set_or_add "$dst_env" "APP_URL" "https://$(domain_url_host "$domain")"
        chown "${name}:${name}" "$dst_env"
    fi

    # A clone of a Reverb app gets its own Reverb, the way it gets its own
    # Octane. Without this the copied BROADCAST_CONNECTION=reverb would point
    # at a server that does not exist on the clone.
    if [[ -n "$(app_get "$src" reverb)" ]]; then
        _app_reverb_enable "$name"
    fi

    # Same for search: the copied SCOUT_DRIVER=meilisearch has no key behind it
    # until the clone gets one of its own, scoped to its own prefix.
    # _search_enable exits on failure, so it runs in a subshell — a search that
    # cannot be set up must not abort a clone that is otherwise complete.
    if [[ -n "$(app_get "$src" search)" && -f "$dst_env" ]]; then
        # shellcheck source=/dev/null
        source "${CIPI_LIB}/search.sh"
        if _search_running; then
            ( _search_enable "$name" ) || warn "Could not enable search for '${name}' — run: cipi search enable ${name}"
        else
            _env_set_or_add "$dst_env" "SCOUT_DRIVER" "database"
            warn "meilisearch is not running — '${name}' was left on SCOUT_DRIVER=database"
        fi
    fi

    if [[ "$with_db" == "true" ]]; then
        # shellcheck source=/dev/null
        source "${CIPI_LIB}/db.sh"
        local dump="/var/log/cipi/backups/${engine}_${src}_clone_$(date +%Y%m%d_%H%M%S).sql.gz"
        mkdir -p /var/log/cipi/backups
        step "Copying database ${src} → ${name}..."
        if db_dump_database "$engine" "$src" "$dump"; then
            if db_restore_database "$engine" "$name" "$dump"; then
                success "Database cloned"
            else
                warn "DB restore failed — empty DB left in place"
            fi
        else
            warn "DB dump failed — empty DB left in place"
        fi
    fi

    # Optional: copy node_build / schedule / limits / predeploy_snapshot
    local nb sch snap
    nb=$(app_get "$src" node_build)
    [[ -n "$nb" ]] && app_set "$name" node_build "$nb" && _sync_node_build_script "$name"
    sch=$(app_get "$src" schedule); [[ -n "$sch" ]] && app_set "$name" schedule "$sch"
    snap=$(app_get "$src" predeploy_snapshot); [[ -n "$snap" ]] && app_set "$name" predeploy_snapshot "$snap"
    local lim
    lim=$(vault_read apps.json | jq -c --arg a "$src" '.[$a].limits // empty')
    [[ -n "$lim" && "$lim" != "null" ]] && app_set_json "$name" limits "$lim"

    log_action "APP CLONE: $src → $name domain=$domain"
    success "Cloned '${src}' → '${name}'. Deploy when ready: cipi deploy ${name}"
}

# Recreate GitHub/GitLab webhook (optionally rotate CIPI_WEBHOOK_TOKEN).
# Usage: cipi app webhook recreate <app> [--rotate-secret]
app_webhook_recreate() {
    local app="${1:-}"; shift || true
    [[ -z "$app" ]] && { error "Usage: cipi app webhook recreate <app> [--rotate-secret]"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    source "${CIPI_LIB}/git.sh"
    git_recreate_webhook "$app" "$@" || exit 1
}

# Restore home / .ssh / .env / storage / logs ownership and modes.
# Usage: cipi app fix-permissions [app]
app_fix_permissions() {
    local app="${1:-}"
    if [[ -n "$app" ]]; then
        app_exists "$app" || { error "App '${app}' not found"; exit 1; }
        step "Restoring permissions for ${app}..."
        ensure_app_permissions "$app"
        log_action "APP PERMISSIONS RESTORED: ${app}"
        success "Permissions restored for ${app}"
        return 0
    fi

    if [[ ! -f "${CIPI_CONFIG}/apps.json" ]]; then
        info "No apps"
        return 0
    fi
    local apps; apps=$(vault_read apps.json | jq -r 'keys[]')
    if [[ -z "$apps" ]]; then
        info "No apps"
        return 0
    fi

    echo -e "\n${BOLD}App permissions${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local n=0
    while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        step "${app}..."
        ensure_app_permissions "$app"
        success "${app}"
        n=$((n + 1))
    done <<< "$apps"
    log_action "APP PERMISSIONS RESTORED: all apps (${n})"
    success "Permissions restored for ${n} app(s)"
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
        convert) app_convert "$@" ;;
        clone)   app_clone "$@" ;;
        reverb)  app_reverb "$@" ;;
        limits)  app_limits "$@" ;;
        env)     app_env "$@" ;;
        webhook)
            if [[ "${1:-}" == "recreate" ]]; then
                shift
                app_webhook_recreate "$@"
            else
                error "Usage: cipi app webhook recreate <app> [--rotate-secret]"
                exit 1
            fi
            ;;
        logs)
            if [[ "${1:-}" == "read" ]]; then
                shift
                app_logs_read "$@"
            else
                app_logs "$@"
            fi
            ;;
        tinker)  app_tinker "$@" ;;
        artisan) app_artisan "$@" ;;
        run)     app_run "$@" ;;
        deploy-config) app_deploy_config "$@" ;;
        suspend)   app_suspend "$@" ;;
        unsuspend) app_unsuspend "$@" ;;
        reset-password)    app_reset_password "$@" ;;
        reset-db-password) app_reset_db_password "$@" ;;
        fix-permissions|fixperms) app_fix_permissions "$@" ;;
        *) error "Unknown: $sub"; echo "Use: create list show edit delete convert clone reverb limits env webhook logs tinker artisan run deploy-config suspend unsuspend reset-password reset-db-password fix-permissions"; echo "      webhook recreate <app> [--rotate-secret]"; echo "      logs read <app> [--type=T] [--page=N] [--per-page=N]  (API snapshot)"; echo "      run --commands [--json]  (list whitelisted binaries)"; exit 1 ;;
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

www_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        add)            www_add "$@" ;;
        force-to-root)  www_force_to_root "$@" ;;
        force-from-root) www_force_from_root "$@" ;;
        clear)          www_clear "$@" ;;
        status)         www_status "$@" ;;
        *) error "Unknown: $sub"; echo "Use: add force-to-root force-from-root clear status"; exit 1 ;;
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
