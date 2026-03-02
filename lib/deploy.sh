#!/bin/bash
#############################################
# Cipi — Deploy Management (Deployer)
#############################################

deploy_command() {
    local app="${1:-}"; shift||true
    [[ -z "$app" ]] && { error "Usage: cipi deploy <app> [--rollback|--releases|--key|--webhook]"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    parse_args "$@"

    if   [[ "${ARG_rollback:-}" == "true" ]]; then _deploy_rollback "$app"
    elif [[ "${ARG_releases:-}" == "true" ]]; then _deploy_releases "$app"
    elif [[ "${ARG_key:-}" == "true" ]];      then _deploy_key "$app"
    elif [[ "${ARG_webhook:-}" == "true" ]];   then _deploy_webhook "$app"
    else _deploy_run "$app"
    fi
}

_deploy_run() {
    local app="$1" home="/home/${app}"
    local df="${home}/.deployer/deploy.php"
    if [[ ! -f "$df" ]]; then
        step "Creating deployer config..."
        source "${CIPI_LIB}/app.sh"
        local repo branch php_ver
        repo=$(app_get "$app" repository)
        branch=$(app_get "$app" branch)
        php_ver=$(app_get "$app" php)
        [[ -z "$repo" || -z "$php_ver" ]] && { error "App config incomplete (repository/php). Run: cipi app edit $app"; exit 1; }
        _create_deployer_config "$app" "${repo}" "${branch:-main}" "$php_ver"
        success "Deployer config created"
    fi

    info "Deploying '${app}'..."
    echo ""
    sudo -u "$app" bash -c "cd ${home} && /usr/local/bin/dep deploy -f ${df} 2>&1"
    local rc=$?
    echo ""
    if [[ $rc -eq 0 ]]; then
        success "Deploy completed"
        log_action "DEPLOY OK: $app"
    else
        error "Deploy failed (exit $rc)"
        warn "Rollback: cipi deploy ${app} --rollback"
        log_action "DEPLOY FAIL: $app exit=$rc"
    fi
}

_deploy_rollback() {
    local app="$1" home="/home/${app}"
    confirm "Rollback '${app}'?" || { info "Cancelled"; return; }
    info "Rolling back..."
    sudo -u "$app" bash -c "cd ${home} && /usr/local/bin/dep rollback -f ${home}/.deployer/deploy.php 2>&1"
    [[ $? -eq 0 ]] && success "Rollback done" || error "Rollback failed"
    log_action "ROLLBACK: $app"
}

_deploy_releases() {
    local app="$1" home="/home/${app}"
    [[ ! -d "${home}/releases" ]] && { info "No releases yet"; return; }
    local current=""
    [[ -L "${home}/current" ]] && current=$(readlink -f "${home}/current" | xargs basename)
    echo -e "\n${BOLD}Releases${NC}"
    ls -1t "${home}/releases" | while read -r r; do
        local mark=""; [[ "$r" == "$current" ]] && mark=" ${GREEN}← current${NC}"
        printf "  ${CYAN}%-20s${NC} %s%b\n" "$r" "$(stat -c '%y' "${home}/releases/${r}" 2>/dev/null|cut -d. -f1)" "$mark"
    done; echo ""
}

_deploy_key() {
    local app="$1" kf="/home/${app}/.ssh/id_ed25519.pub"
    [[ ! -f "$kf" ]] && { error "Key not found"; exit 1; }
    echo -e "\n${BOLD}Deploy Key for '${app}'${NC}"
    echo -e "${CYAN}$(cat "$kf")${NC}\n"
    echo "Add as Deploy Key in:"
    echo "  GitHub:    Repo → Settings → Deploy keys"
    echo "  GitLab:    Repo → Settings → Repository → Deploy keys"
    echo "  Bitbucket: Repo → Settings → Access keys"
    echo "  Gitea:     Repo → Settings → Deploy Keys"
    echo ""
}

_deploy_webhook() {
    local app="$1"
    local d; d=$(app_get "$app" domain)
    local t; t=$(app_get "$app" webhook_token)
    echo -e "\n${BOLD}Webhook for '${app}'${NC}"
    echo -e "  URL:   ${CYAN}https://${d}/cipi/webhook${NC}"
    echo -e "  Token: ${CYAN}${t}${NC}"
    echo ""
    echo "  GitHub: Repo → Settings → Webhooks → Add"
    echo "    Payload URL: https://${d}/cipi/webhook"
    echo "    Secret: ${t}"
    echo "    Events: Push only"
    echo ""
    echo "  GitLab: Repo → Settings → Webhooks"
    echo "    URL: https://${d}/cipi/webhook"
    echo "    Secret token: ${t}"
    echo ""
    echo "  Requires: composer require cipi/agent"
    echo ""
}
