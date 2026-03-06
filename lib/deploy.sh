#!/bin/bash
#############################################
# Cipi — Deploy Management (Deployer)
#############################################

deploy_command() {
    local app="${1:-}"; shift||true
    [[ -z "$app" ]] && { error "Usage: cipi deploy <app> [--rollback|--releases|--key|--webhook]"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    parse_args "$@"

    if   [[ "${ARG_rollback:-}" == "true" ]];        then _deploy_rollback "$app"
    elif [[ "${ARG_releases:-}" == "true" ]];        then _deploy_releases "$app"
    elif [[ "${ARG_key:-}" == "true" ]];             then _deploy_key "$app"
    elif [[ "${ARG_webhook:-}" == "true" ]];         then _deploy_webhook "$app"
    elif [[ "${ARG_unlock:-}" == "true" ]];          then _deploy_unlock "$app"
    elif [[ -n "${ARG_trust_host:-}" ]];             then _deploy_trust_host "$app" "${ARG_trust_host}"
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

_deploy_unlock() {
    local app="$1" home="/home/${app}"
    local lockfile="${home}/.dep/deploy.lock"
    if [[ ! -f "$lockfile" ]]; then
        info "No deploy lock found for '${app}'"
        return 0
    fi
    rm -f "$lockfile"
    success "Deploy unlocked — run: cipi deploy ${app}"
    log_action "DEPLOY UNLOCK: $app"
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

    local git_prov; git_prov=$(app_get "$app" git_provider)
    local git_dkid; git_dkid=$(app_get "$app" git_deploy_key_id)
    if [[ -n "$git_prov" && -n "$git_dkid" ]]; then
        echo -e "  ${GREEN}✓ Auto-configured on ${git_prov} (ID: ${git_dkid})${NC}"
    else
        echo "Add as Deploy Key in your Git provider:"
        echo "  GitHub:  Repo → Settings → Deploy keys → Add deploy key"
        echo "  GitLab:  Repo → Settings → Repository → Deploy keys"
        echo "  Gitea:   Repo → Settings → Deploy keys → Add key"
        echo "  Forgejo: Repo → Settings → Deploy keys → Add key"
        echo "  Custom:  append to ~/.ssh/authorized_keys on the git server"
    fi
    echo ""
    echo "  Trust the host fingerprint with:"
    echo "  ${CYAN}cipi deploy ${app} --trust-host=<host[:port]>${NC}"
    echo ""
}

_deploy_trust_host() {
    local app="$1" hostport="$2"
    local home="/home/${app}" known_hosts

    # Split host and optional port
    local host port
    if [[ "$hostport" == *:* ]]; then
        host="${hostport%%:*}"
        port="${hostport##*:}"
    else
        host="$hostport"
        port="22"
    fi

    [[ -z "$host" ]] && { error "Usage: cipi deploy <app> --trust-host=<host[:port]>"; exit 1; }

    known_hosts="${home}/.ssh/known_hosts"

    step "Scanning SSH fingerprint of ${host}:${port}..."
    local scan_out
    if [[ "$port" == "22" ]]; then
        scan_out=$(ssh-keyscan -T 10 -H "$host" 2>/dev/null)
    else
        scan_out=$(ssh-keyscan -T 10 -p "$port" -H "$host" 2>/dev/null)
    fi

    if [[ -z "$scan_out" ]]; then
        error "Could not reach ${host}:${port} — check the hostname and that port ${port} is open"
        exit 1
    fi

    # Remove any existing entry for this host to avoid duplicates
    if [[ -f "$known_hosts" ]]; then
        local tmp; tmp=$(mktemp)
        ssh-keygen -R "$host" -f "$known_hosts" &>/dev/null || true
        [[ "$port" != "22" ]] && ssh-keygen -R "[${host}]:${port}" -f "$known_hosts" &>/dev/null || true
    fi

    echo "$scan_out" >> "$known_hosts"
    chown "${app}:${app}" "$known_hosts"
    chmod 600 "$known_hosts"

    success "Fingerprint of ${host}:${port} trusted for '${app}'"
    echo ""
    echo -e "${BOLD}Fingerprints added:${NC}"
    echo "$scan_out" | awk '{print "  " $0}' | cut -c1-80
    echo ""

    # Show the deploy key as a reminder
    local kf="${home}/.ssh/id_ed25519.pub"
    if [[ -f "$kf" ]]; then
        echo -e "${BOLD}Deploy Key${NC} (add this to your Git server):"
        echo -e "  ${CYAN}$(cat "$kf")${NC}"
        echo ""
    fi

    # If non-standard port, write/update SSH config entry
    if [[ "$port" != "22" ]]; then
        local ssh_cfg="${home}/.ssh/config"
        # Remove existing Host block for this host if any
        if [[ -f "$ssh_cfg" ]]; then
            local tmp; tmp=$(mktemp)
            awk -v h="$host" '
                /^Host / { in_block = ($2 == h) }
                !in_block { print }
            ' "$ssh_cfg" > "$tmp" && mv "$tmp" "$ssh_cfg"
        fi
        cat >> "$ssh_cfg" <<SSHCFG

Host ${host}
    HostName ${host}
    Port ${port}
    IdentityFile ${home}/.ssh/id_ed25519
    StrictHostKeyChecking accept-new
SSHCFG
        chown "${app}:${app}" "$ssh_cfg"
        chmod 600 "$ssh_cfg"
        success "SSH config updated (port ${port} → ${host})"
    fi

    log_action "TRUST HOST: $app → ${host}:${port}"
}

_deploy_webhook() {
    local app="$1"
    local d; d=$(app_get "$app" domain)
    local t; t=$(app_get "$app" webhook_token)
    echo -e "\n${BOLD}Webhook for '${app}'${NC}"
    echo -e "  URL:   ${CYAN}https://${d}/cipi/webhook${NC}"
    echo -e "  Token: ${CYAN}${t}${NC}"
    echo ""

    local git_prov; git_prov=$(app_get "$app" git_provider)
    local git_whid; git_whid=$(app_get "$app" git_webhook_id)
    if [[ -n "$git_prov" && -n "$git_whid" ]]; then
        echo -e "  ${GREEN}✓ Auto-configured on ${git_prov} (ID: ${git_whid})${NC}"
    else
        echo "  GitHub: Repo → Settings → Webhooks → Add"
        echo "    Payload URL: https://${d}/cipi/webhook"
        echo "    Secret: ${t}"
        echo "    Events: Push only"
        echo ""
        echo "  GitLab: Repo → Settings → Webhooks"
        echo "    URL: https://${d}/cipi/webhook"
        echo "    Secret token: ${t}"
    fi
    echo ""
    echo "  Requires: composer require cipi/agent"
    echo ""
}
