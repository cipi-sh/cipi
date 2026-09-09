#!/bin/bash
#############################################
# Cipi — Git Provider Integration
# GitHub & GitLab deploy key + webhook automation
#############################################

# ── SERVER.JSON HELPERS ──────────────────────────────────────

_git_server_get() {
    vault_read server.json | jq -r --arg k "$1" '.[$k] // empty'
}

_git_server_set() {
    vault_read server.json | jq --arg k "$1" --arg v "$2" '.[$k] = $v' | vault_write server.json
}

_git_server_remove() {
    vault_read server.json | jq --arg k "$1" 'del(.[$k])' | vault_write server.json
}

# ── DETECT PROVIDER ──────────────────────────────────────────

# Returns: github, gitlab, or empty
_git_detect_provider() {
    local url="$1"
    if [[ "$url" == *"github.com"* ]]; then
        echo "github"
    elif [[ "$url" == *"gitlab"* ]]; then
        echo "gitlab"
    fi
}

# ── PARSE REPO URL ───────────────────────────────────────────

# GitHub: git@github.com:user/repo.git → user/repo
_git_parse_github_repo() {
    echo "$1" | sed -E 's|.*github\.com[:/](.+)\.git$|\1|; s|.*github\.com[:/](.+)$|\1|'
}

# GitLab: git@gitlab.com:user/repo.git → user%2Frepo (URL-encoded for API)
_git_parse_gitlab_project() {
    local path
    local gitlab_url; gitlab_url=$(_git_server_get "gitlab_url")
    [[ -z "$gitlab_url" ]] && gitlab_url="https://gitlab.com"
    local host; host=$(echo "$gitlab_url" | sed -E 's|https?://||; s|/$||')
    path=$(echo "$1" | sed -E "s|.*${host}[:/](.+)\\.git$|\\1|; s|.*${host}[:/](.+)$|\\1|")
    echo "$path" | sed 's|/|%2F|g'
}

# ── GITHUB API ───────────────────────────────────────────────

_github_api() {
    local method="$1" endpoint="$2" data="${3:-}"
    local token; token=$(_git_server_get "github_token")
    [[ -z "$token" ]] && return 1

    local args=(-sS --connect-timeout 10 --max-time 30 -w "\n%{http_code}" -X "$method"
        -H "Accept: application/vnd.github+json"
        -H "Authorization: Bearer ${token}"
        -H "X-GitHub-Api-Version: 2022-11-28")
    [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" -d "$data")

    curl "${args[@]}" "https://api.github.com${endpoint}"
}

_git_http_code() { printf '%s\n' "$1" | tail -1; }
_git_http_body() { printf '%s\n' "$1" | sed '$d'; }

# ssh-ed25519 AAAA... comment → type + material (ignore comment)
_git_key_blob() { awk '{print $1, $2}' <<< "$1"; }

_github_get_json() {
    local endpoint="$1"
    local resp; resp=$(_github_api GET "$endpoint") || true
    local code; code=$(_git_http_code "$resp")
    local body; body=$(_git_http_body "$resp")
    case "$code" in
        200) printf '%s\n' "$body"; return 0 ;;
        401|403)
            error "GitHub token rejected (HTTP ${code}) — update with: cipi git github-token <token>"
            return 1 ;;
        *) return 1 ;;
    esac
}

_github_find_deploy_key_id() {
    local owner_repo="$1" pub_key="$2"
    local blob; blob=$(_git_key_blob "$pub_key")
    [[ -z "$blob" ]] && return 1
    local keys; keys=$(_github_get_json "/repos/${owner_repo}/keys?per_page=100") || return 1
    echo "$keys" | jq -r --arg b "$blob" \
        '[.[] | select((.key | split(" ") | (.[0] + " " + .[1])) == $b) | .id] | first // empty'
}

_github_find_webhook_ids() {
    local owner_repo="$1" webhook_url="$2"
    local hooks; hooks=$(_github_get_json "/repos/${owner_repo}/hooks?per_page=100") || return 1
    echo "$hooks" | jq -r --arg u "$webhook_url" '.[] | select(.config.url == $u) | .id'
}

_github_remove_deploy_keys_by_title() {
    local owner_repo="$1" title="$2"
    local keys; keys=$(_github_get_json "/repos/${owner_repo}/keys?per_page=100") || return 0
    local ids; ids=$(echo "$keys" | jq -r --arg t "$title" '.[] | select(.title == $t) | .id')
    local id
    for id in $ids; do
        _github_remove_deploy_key "$owner_repo" "$id" 2>/dev/null || true
    done
}

_github_add_deploy_key() {
    local owner_repo="$1" title="$2" pub_key="$3"
    local payload; payload=$(jq -n --arg t "$title" --arg k "$pub_key" '{title: $t, key: $k, read_only: true}')
    local resp; resp=$(_github_api POST "/repos/${owner_repo}/keys" "$payload")
    local code; code=$(_git_http_code "$resp")
    local body; body=$(_git_http_body "$resp")

    if [[ "$code" == "201" ]]; then
        echo "$body" | jq -r '.id'
        return 0
    fi
    # Same pubkey already on this repo (often after a lost git_deploy_key_id).
    if [[ "$code" == "422" ]]; then
        local existing; existing=$(_github_find_deploy_key_id "$owner_repo" "$pub_key") || true
        if [[ -n "$existing" && "$existing" != "null" ]]; then
            echo "$existing"
            return 0
        fi
    fi
    error "GitHub deploy key failed (HTTP ${code}): $(echo "$body" | jq -r '.message // empty')"
    return 1
}

_github_remove_deploy_key() {
    local owner_repo="$1" key_id="$2"
    [[ -z "$key_id" || "$key_id" == "null" ]] && return 0
    local resp; resp=$(_github_api DELETE "/repos/${owner_repo}/keys/${key_id}")
    local code; code=$(echo "$resp" | tail -1)
    [[ "$code" == "204" || "$code" == "404" ]] && return 0
    warn "GitHub remove deploy key: HTTP ${code}"
    return 1
}

_github_add_webhook() {
    local owner_repo="$1" webhook_url="$2" secret="$3"
    local payload; payload=$(jq -n --arg u "$webhook_url" --arg s "$secret" \
        '{name: "web", active: true, events: ["push"], config: {url: $u, secret: $s, content_type: "json", insecure_ssl: "0"}}')
    local resp; resp=$(_github_api POST "/repos/${owner_repo}/hooks" "$payload")
    local code; code=$(echo "$resp" | tail -1)
    local body; body=$(echo "$resp" | sed '$d')

    if [[ "$code" == "201" ]]; then
        echo "$body" | jq -r '.id'
        return 0
    fi
    error "GitHub webhook failed (HTTP ${code}): $(echo "$body" | jq -r '.message // empty')"
    return 1
}

_github_remove_webhook() {
    local owner_repo="$1" hook_id="$2"
    [[ -z "$hook_id" || "$hook_id" == "null" ]] && return 0
    local resp; resp=$(_github_api DELETE "/repos/${owner_repo}/hooks/${hook_id}")
    local code; code=$(echo "$resp" | tail -1)
    [[ "$code" == "204" || "$code" == "404" ]] && return 0
    warn "GitHub remove webhook: HTTP ${code}"
    return 1
}

# ── GITLAB API ───────────────────────────────────────────────

_gitlab_api() {
    local method="$1" endpoint="$2" data="${3:-}"
    local token; token=$(_git_server_get "gitlab_token")
    [[ -z "$token" ]] && return 1

    local base_url; base_url=$(_git_server_get "gitlab_url")
    [[ -z "$base_url" ]] && base_url="https://gitlab.com"

    local args=(-sS --connect-timeout 10 --max-time 30 -w "\n%{http_code}" -X "$method"
        -H "PRIVATE-TOKEN: ${token}")
    [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" -d "$data")

    curl "${args[@]}" "${base_url}/api/v4${endpoint}"
}

_gitlab_get_json() {
    local endpoint="$1"
    local resp; resp=$(_gitlab_api GET "$endpoint") || true
    local code; code=$(_git_http_code "$resp")
    local body; body=$(_git_http_body "$resp")
    case "$code" in
        200) printf '%s\n' "$body"; return 0 ;;
        401|403)
            error "GitLab token rejected (HTTP ${code}) — update with: cipi git gitlab-token <token>"
            return 1 ;;
        *) return 1 ;;
    esac
}

_gitlab_find_deploy_key_id() {
    local project_id="$1" pub_key="$2"
    local blob; blob=$(_git_key_blob "$pub_key")
    [[ -z "$blob" ]] && return 1
    local keys; keys=$(_gitlab_get_json "/projects/${project_id}/deploy_keys?per_page=100") || return 1
    echo "$keys" | jq -r --arg b "$blob" \
        '[.[] | select((.key | split(" ") | (.[0] + " " + .[1])) == $b) | .id] | first // empty'
}

_gitlab_find_webhook_ids() {
    local project_id="$1" webhook_url="$2"
    local hooks; hooks=$(_gitlab_get_json "/projects/${project_id}/hooks?per_page=100") || return 1
    echo "$hooks" | jq -r --arg u "$webhook_url" '.[] | select(.url == $u) | .id'
}

_gitlab_remove_deploy_keys_by_title() {
    local project_id="$1" title="$2"
    local keys; keys=$(_gitlab_get_json "/projects/${project_id}/deploy_keys?per_page=100") || return 0
    local ids; ids=$(echo "$keys" | jq -r --arg t "$title" '.[] | select(.title == $t) | .id')
    local id
    for id in $ids; do
        _gitlab_remove_deploy_key "$project_id" "$id" 2>/dev/null || true
    done
}

_gitlab_add_deploy_key() {
    local project_id="$1" title="$2" pub_key="$3"
    local payload; payload=$(jq -n --arg t "$title" --arg k "$pub_key" '{title: $t, key: $k, can_push: false}')
    local resp; resp=$(_gitlab_api POST "/projects/${project_id}/deploy_keys" "$payload")
    local code; code=$(_git_http_code "$resp")
    local body; body=$(_git_http_body "$resp")

    if [[ "$code" == "201" ]]; then
        echo "$body" | jq -r '.id'
        return 0
    fi
    if [[ "$code" == "400" || "$code" == "422" ]]; then
        local existing; existing=$(_gitlab_find_deploy_key_id "$project_id" "$pub_key") || true
        if [[ -n "$existing" && "$existing" != "null" ]]; then
            echo "$existing"
            return 0
        fi
    fi
    error "GitLab deploy key failed (HTTP ${code}): $(echo "$body" | jq -r '.message // empty')"
    return 1
}

_gitlab_remove_deploy_key() {
    local project_id="$1" key_id="$2"
    [[ -z "$key_id" || "$key_id" == "null" ]] && return 0
    local resp; resp=$(_gitlab_api DELETE "/projects/${project_id}/deploy_keys/${key_id}")
    local code; code=$(echo "$resp" | tail -1)
    [[ "$code" == "204" || "$code" == "200" || "$code" == "404" ]] && return 0
    warn "GitLab remove deploy key: HTTP ${code}"
    return 1
}

_gitlab_add_webhook() {
    local project_id="$1" webhook_url="$2" secret="$3"
    local payload; payload=$(jq -n --arg u "$webhook_url" --arg s "$secret" \
        '{url: $u, token: $s, push_events: true, enable_ssl_verification: true}')
    local resp; resp=$(_gitlab_api POST "/projects/${project_id}/hooks" "$payload")
    local code; code=$(echo "$resp" | tail -1)
    local body; body=$(echo "$resp" | sed '$d')

    if [[ "$code" == "201" ]]; then
        echo "$body" | jq -r '.id'
        return 0
    fi
    error "GitLab webhook failed (HTTP ${code}): $(echo "$body" | jq -r '.message // empty')"
    return 1
}

_gitlab_remove_webhook() {
    local project_id="$1" hook_id="$2"
    [[ -z "$hook_id" || "$hook_id" == "null" ]] && return 0
    local resp; resp=$(_gitlab_api DELETE "/projects/${project_id}/hooks/${hook_id}")
    local code; code=$(echo "$resp" | tail -1)
    [[ "$code" == "204" || "$code" == "200" || "$code" == "404" ]] && return 0
    warn "GitLab remove webhook: HTTP ${code}"
    return 1
}

# ── HIGH-LEVEL ORCHESTRATION ─────────────────────────────────

# Setup deploy key + webhook on the git provider.
# Sets: GIT_DEPLOY_KEY_ID, GIT_WEBHOOK_ID, GIT_PROVIDER
# Arg 6: "skip_webhook" — only add deploy key (e.g. for WordPress apps; no Laravel webhook).
git_setup_repo() {
    local app="$1" repository="$2" domain="$3" webhook_token="$4" pub_key="$5" skip_webhook="${6:-}"
    local provider; provider=$(_git_detect_provider "$repository")

    GIT_PROVIDER="" GIT_DEPLOY_KEY_ID="" GIT_WEBHOOK_ID=""
    [[ -z "$provider" ]] && return 0

    local token_key="${provider}_token"
    local token; token=$(_git_server_get "$token_key")
    if [[ -z "$token" ]]; then
        info "No ${provider} token configured — skipping auto-setup (manual config needed)"
        info "Set it with: cipi git ${provider}-token <token>"
        return 0
    fi

    GIT_PROVIDER="$provider"
    local webhook_url="https://$(domain_url_host "$domain")/cipi/webhook"

    step "Configuring ${provider} integration..."

    if [[ "$provider" == "github" ]]; then
        local owner_repo; owner_repo=$(_git_parse_github_repo "$repository")
        GIT_DEPLOY_KEY_ID=$(_github_add_deploy_key "$owner_repo" "cipi:${app}" "$pub_key" 2>&1) || {
            warn "Could not add deploy key to GitHub — add it manually"
            GIT_DEPLOY_KEY_ID=""
        }
        if [[ "$skip_webhook" != "skip_webhook" && -n "$webhook_token" ]]; then
            GIT_WEBHOOK_ID=$(_github_add_webhook "$owner_repo" "$webhook_url" "$webhook_token" 2>&1) || {
                warn "Could not add webhook to GitHub — add it manually"
                GIT_WEBHOOK_ID=""
            }
        fi
    elif [[ "$provider" == "gitlab" ]]; then
        local project_id; project_id=$(_git_parse_gitlab_project "$repository")
        GIT_DEPLOY_KEY_ID=$(_gitlab_add_deploy_key "$project_id" "cipi:${app}" "$pub_key" 2>&1) || {
            warn "Could not add deploy key to GitLab — add it manually"
            GIT_DEPLOY_KEY_ID=""
        }
        if [[ "$skip_webhook" != "skip_webhook" && -n "$webhook_token" ]]; then
            GIT_WEBHOOK_ID=$(_gitlab_add_webhook "$project_id" "$webhook_url" "$webhook_token" 2>&1) || {
                warn "Could not add webhook to GitLab — add it manually"
                GIT_WEBHOOK_ID=""
            }
        fi
    fi

    if [[ "$skip_webhook" == "skip_webhook" ]]; then
        [[ -n "$GIT_DEPLOY_KEY_ID" ]] && success "${provider} deploy key configured (webhook skipped)"
    elif [[ -n "$GIT_DEPLOY_KEY_ID" && -n "$GIT_WEBHOOK_ID" ]]; then
        success "${provider} deploy key + webhook configured automatically"
    elif [[ -n "$GIT_DEPLOY_KEY_ID" ]]; then
        success "${provider} deploy key added (webhook needs manual setup)"
    elif [[ -n "$GIT_WEBHOOK_ID" ]]; then
        success "${provider} webhook added (deploy key needs manual setup)"
    fi
}

# Remove deploy key + webhook from git provider
git_cleanup_repo() {
    local app="$1" repository="$2"
    local provider; provider=$(app_get "$app" git_provider 2>/dev/null || true)
    local key_id; key_id=$(app_get "$app" git_deploy_key_id 2>/dev/null || true)
    local hook_id; hook_id=$(app_get "$app" git_webhook_id 2>/dev/null || true)

    [[ -z "$provider" ]] && return 0
    [[ -z "$key_id" && -z "$hook_id" ]] && return 0

    local token_key="${provider}_token"
    local token; token=$(_git_server_get "$token_key")
    [[ -z "$token" ]] && {
        warn "No ${provider} token — cannot remove deploy key/webhook from repo automatically"
        return 0
    }

    step "Removing ${provider} integration..."

    if [[ "$provider" == "github" ]]; then
        local owner_repo; owner_repo=$(_git_parse_github_repo "$repository")
        _github_remove_deploy_key "$owner_repo" "$key_id" 2>/dev/null || true
        _github_remove_webhook "$owner_repo" "$hook_id" 2>/dev/null || true
    elif [[ "$provider" == "gitlab" ]]; then
        local project_id; project_id=$(_git_parse_gitlab_project "$repository")
        _gitlab_remove_deploy_key "$project_id" "$key_id" 2>/dev/null || true
        _gitlab_remove_webhook "$project_id" "$hook_id" 2>/dev/null || true
    fi

    success "${provider} deploy key + webhook removed"
}

# Save git integration data into apps.json (uses jq numeric for IDs)
git_save_app_data() {
    local app="$1" provider="$2" key_id="$3" hook_id="$4"

    if [[ -n "$provider" ]]; then
        app_set "$app" git_provider "$provider"
    fi
    if [[ -n "$key_id" ]]; then
        vault_read apps.json | jq --arg a "$app" --argjson v "$key_id" '.[$a].git_deploy_key_id = $v' | vault_write apps.json
        ensure_apps_json_api_access
    fi
    if [[ -n "$hook_id" ]]; then
        vault_read apps.json | jq --arg a "$app" --argjson v "$hook_id" '.[$a].git_webhook_id = $v' | vault_write apps.json
        ensure_apps_json_api_access
    fi
}

# Remove git integration data from apps.json
git_clear_app_data() {
    local app="$1"
    vault_read apps.json | jq --arg a "$app" 'del(.[$a].git_provider, .[$a].git_deploy_key_id, .[$a].git_webhook_id)' | vault_write apps.json
    ensure_apps_json_api_access
}

# Recreate provider webhook (same or new secret). Deploy key unchanged.
# Usage: git_recreate_webhook <app> [--rotate-secret]
# Prints WEBHOOK_URL / WEBHOOK_TOKEN / WEBHOOK_ID lines for API parsers.
git_recreate_webhook() {
    local app="$1"
    shift || true
    parse_args "$@"
    local rotate="${ARG_rotate_secret:-}"

    local repository domain provider hook_id wt token webhook_url
    repository=$(app_get "$app" repository 2>/dev/null || true)
    domain=$(app_get "$app" domain 2>/dev/null || true)
    provider=$(app_get "$app" git_provider 2>/dev/null || true)
    hook_id=$(app_get "$app" git_webhook_id 2>/dev/null || true)
    wt=$(app_get "$app" webhook_token 2>/dev/null || true)

    [[ -z "$repository" ]] && { error "App '${app}' has no repository"; return 1; }
    [[ -z "$domain" ]] && { error "App '${app}' has no domain"; return 1; }
    [[ -z "$wt" ]] && { error "App '${app}' has no webhook token (custom/SFTP apps have no webhook)"; return 1; }

    provider="${provider:-$(_git_detect_provider "$repository")}"
    [[ -z "$provider" ]] && { error "Unsupported git provider for ${repository}"; return 1; }

    token=$(_git_server_get "${provider}_token")
    [[ -z "$token" ]] && {
        error "No ${provider} token — set with: cipi git ${provider}-token <token>"
        return 1
    }

    if [[ "$rotate" == "true" ]]; then
        step "Rotating webhook secret..."
        wt=$(generate_token)
        app_set "$app" webhook_token "$wt"
        if [[ -f "/home/${app}/shared/.env" ]]; then
            if grep -q '^CIPI_WEBHOOK_TOKEN=' "/home/${app}/shared/.env" 2>/dev/null; then
                sed -i "s|^CIPI_WEBHOOK_TOKEN=.*|CIPI_WEBHOOK_TOKEN=${wt}|" "/home/${app}/shared/.env"
            else
                echo "CIPI_WEBHOOK_TOKEN=${wt}" >> "/home/${app}/shared/.env"
            fi
            success "CIPI_WEBHOOK_TOKEN updated in shared/.env"
        fi
    fi

    webhook_url="https://$(domain_url_host "$domain")/cipi/webhook"
    step "Recreating ${provider} webhook..."

    local new_hook_id=""
    if [[ "$provider" == "github" ]]; then
        local owner_repo; owner_repo=$(_git_parse_github_repo "$repository")
        [[ -n "$hook_id" ]] && _github_remove_webhook "$owner_repo" "$hook_id" 2>/dev/null || true
        new_hook_id=$(_github_add_webhook "$owner_repo" "$webhook_url" "$wt" 2>&1) || {
            error "Could not recreate GitHub webhook: ${new_hook_id}"
            return 1
        }
    elif [[ "$provider" == "gitlab" ]]; then
        local project_id; project_id=$(_git_parse_gitlab_project "$repository")
        [[ -n "$hook_id" ]] && _gitlab_remove_webhook "$project_id" "$hook_id" 2>/dev/null || true
        new_hook_id=$(_gitlab_add_webhook "$project_id" "$webhook_url" "$wt" 2>&1) || {
            error "Could not recreate GitLab webhook: ${new_hook_id}"
            return 1
        }
    else
        error "Unsupported provider: ${provider}"
        return 1
    fi

    if [[ -z "$new_hook_id" || "$new_hook_id" == "null" ]]; then
        error "Webhook recreate failed — empty hook id"
        return 1
    fi

    app_set "$app" git_provider "$provider"
    vault_read apps.json | jq --arg a "$app" --argjson v "$new_hook_id" '.[$a].git_webhook_id = $v' | vault_write apps.json
    ensure_apps_json_api_access

    log_action "WEBHOOK RECREATED: $app provider=$provider rotate=${rotate:-false}"
    success "Webhook recreated for ${app}"
    echo "WEBHOOK_URL: ${webhook_url}"
    echo "WEBHOOK_TOKEN: ${wt}"
    echo "WEBHOOK_ID: ${new_hook_id}"
    echo "WEBHOOK_ROTATED: ${rotate:-false}"
}

# Recreate the provider webhook after a primary domain change (deploy key unchanged).
git_update_webhook_domain() {
    local app="$1" domain="$2" repository="$3"
    local provider hook_id key_id wt token

    provider=$(app_get "$app" git_provider 2>/dev/null || true)
    hook_id=$(app_get "$app" git_webhook_id 2>/dev/null || true)
    key_id=$(app_get "$app" git_deploy_key_id 2>/dev/null || true)
    wt=$(app_get "$app" webhook_token 2>/dev/null || true)

    [[ -z "$provider" || -z "$hook_id" || -z "$wt" || -z "$repository" ]] && return 0

    token=$(_git_server_get "${provider}_token")
    [[ -z "$token" ]] && {
        warn "No ${provider} token — update webhook URL manually: https://$(domain_url_host "$domain")/cipi/webhook"
        return 0
    }

    local webhook_url="https://$(domain_url_host "$domain")/cipi/webhook"
    step "Updating ${provider} webhook..."

    local new_hook_id=""
    if [[ "$provider" == "github" ]]; then
        local owner_repo; owner_repo=$(_git_parse_github_repo "$repository")
        _github_remove_webhook "$owner_repo" "$hook_id" 2>/dev/null || true
        new_hook_id=$(_github_add_webhook "$owner_repo" "$webhook_url" "$wt" 2>&1) || {
            warn "Could not update GitHub webhook — set manually: ${webhook_url}"
            return 0
        }
    elif [[ "$provider" == "gitlab" ]]; then
        local project_id; project_id=$(_git_parse_gitlab_project "$repository")
        _gitlab_remove_webhook "$project_id" "$hook_id" 2>/dev/null || true
        new_hook_id=$(_gitlab_add_webhook "$project_id" "$webhook_url" "$wt" 2>&1) || {
            warn "Could not update GitLab webhook — set manually: ${webhook_url}"
            return 0
        }
    fi

    if [[ -n "$new_hook_id" ]]; then
        vault_read apps.json | jq --arg a "$app" --argjson v "$new_hook_id" '.[$a].git_webhook_id = $v' | vault_write apps.json
        ensure_apps_json_api_access
        success "${provider} webhook → ${domain}"
    fi
}

# Generate a new ed25519 deploy key for an app and swap it in authorized_keys
# (Deployer SSHs to localhost with this key). Prints the new public key.
_git_rotate_local_key() {
    local app="$1"
    local home="/home/${app}"
    local old_pub=""
    [[ -f "${home}/.ssh/id_ed25519.pub" ]] && old_pub=$(cat "${home}/.ssh/id_ed25519.pub")
    mkdir -p "${home}/.ssh"
    chmod 700 "${home}/.ssh"
    chown "${app}:${app}" "${home}/.ssh"
    rm -f "${home}/.ssh/id_ed25519" "${home}/.ssh/id_ed25519.pub"
    sudo -u "$app" ssh-keygen -t ed25519 -C "${app}@cipi" -f "${home}/.ssh/id_ed25519" -N "" -q
    chmod 600 "${home}/.ssh/id_ed25519"
    chmod 644 "${home}/.ssh/id_ed25519.pub"
    chown "${app}:${app}" "${home}/.ssh/id_ed25519" "${home}/.ssh/id_ed25519.pub"
    local new_pub; new_pub=$(cat "${home}/.ssh/id_ed25519.pub")
    local ak="${home}/.ssh/authorized_keys"
    touch "$ak"
    if [[ -n "$old_pub" ]]; then
        local blob; blob=$(_git_key_blob "$old_pub")
        if [[ -n "$blob" ]]; then
            local tmp; tmp=$(mktemp)
            grep -vF "$blob" "$ak" > "$tmp" || true
            printf '%s\n' "$new_pub" >> "$tmp"
            mv "$tmp" "$ak"
        else
            printf '%s\n' "$new_pub" >> "$ak"
        fi
    else
        printf '%s\n' "$new_pub" >> "$ak"
    fi
    chown "${app}:${app}" "$ak"
    chmod 600 "$ak"
    chmod 700 "${home}/.ssh"
    printf '%s\n' "$new_pub"
}

# Re-register this app's local deploy key and webhook on GitHub/GitLab.
# Recovers from vanished remote objects and stale IDs in apps.json.
# rotate_keys / rotate_secret: "true" to mint new local material first.
git_refresh_app() {
    local app="$1"
    local rotate_keys="${2:-}"
    local rotate_secret="${3:-}"

    local repository domain custom wt provider key_id hook_id
    repository=$(app_get "$app" repository 2>/dev/null || true)
    domain=$(app_get "$app" domain 2>/dev/null || true)
    custom=$(app_get "$app" custom 2>/dev/null || true)
    wt=$(app_get "$app" webhook_token 2>/dev/null || true)
    key_id=$(app_get "$app" git_deploy_key_id 2>/dev/null || true)
    hook_id=$(app_get "$app" git_webhook_id 2>/dev/null || true)

    if [[ -z "$repository" ]]; then
        info "${app}: no git repository — skipped"
        return 0
    fi
    provider=$(_git_detect_provider "$repository")
    if [[ -z "$provider" ]]; then
        info "${app}: unsupported git host — skipped"
        return 0
    fi
    local token; token=$(_git_server_get "${provider}_token")
    if [[ -z "$token" ]]; then
        warn "${app}: no ${provider} token — skipped (cipi git ${provider}-token <token>)"
        return 1
    fi
    if [[ -z "$domain" ]]; then
        error "${app}: no domain"
        return 1
    fi

    echo ""
    echo -e "${BOLD}${app}${NC} (${provider})"

    local home="/home/${app}"
    local pub_path="${home}/.ssh/id_ed25519.pub"
    local pub_key=""
    local did_rotate_keys="false"

    if [[ "$rotate_keys" == "true" ]]; then
        step "Rotating SSH deploy key..."
        pub_key=$(_git_rotate_local_key "$app") || {
            error "${app}: could not rotate SSH key"
            return 1
        }
        did_rotate_keys="true"
        success "New SSH key generated"
    elif [[ ! -f "$pub_path" ]]; then
        step "Generating missing SSH deploy key..."
        pub_key=$(_git_rotate_local_key "$app") || {
            error "${app}: could not generate SSH key"
            return 1
        }
        did_rotate_keys="true"
        success "SSH key generated"
    else
        pub_key=$(cat "$pub_path")
    fi

    local webhook_url="https://$(domain_url_host "$domain")/cipi/webhook"
    local skip_webhook="true"
    if [[ "$custom" != "true" && -n "$wt" ]]; then
        skip_webhook="false"
    fi

    if [[ "$skip_webhook" == "false" && "$rotate_secret" == "true" ]]; then
        step "Rotating webhook secret..."
        wt=$(generate_token)
        app_set "$app" webhook_token "$wt"
        if [[ -f "${home}/shared/.env" ]]; then
            if grep -q '^CIPI_WEBHOOK_TOKEN=' "${home}/shared/.env" 2>/dev/null; then
                sed -i "s|^CIPI_WEBHOOK_TOKEN=.*|CIPI_WEBHOOK_TOKEN=${wt}|" "${home}/shared/.env"
            else
                echo "CIPI_WEBHOOK_TOKEN=${wt}" >> "${home}/shared/.env"
            fi
        fi
        success "Webhook secret rotated"
    fi

    local new_key_id="" new_hook_id=""
    local title="cipi:${app}"

    step "Refreshing ${provider} deploy key..."
    if [[ "$provider" == "github" ]]; then
        local owner_repo; owner_repo=$(_git_parse_github_repo "$repository")
        [[ -n "$key_id" ]] && _github_remove_deploy_key "$owner_repo" "$key_id" 2>/dev/null || true
        _github_remove_deploy_keys_by_title "$owner_repo" "$title" || true
        new_key_id=$(_github_add_deploy_key "$owner_repo" "$title" "$pub_key") || new_key_id=""
        if [[ -z "$new_key_id" || "$new_key_id" == "null" ]]; then
            new_key_id=$(_github_find_deploy_key_id "$owner_repo" "$pub_key") || true
        fi
        # Same pubkey already used as a deploy key on another GitHub repo.
        if [[ -z "$new_key_id" || "$new_key_id" == "null" ]] && [[ "$did_rotate_keys" != "true" ]]; then
            warn "${app}: deploy key already used on another repo — generating a new one"
            pub_key=$(_git_rotate_local_key "$app") || {
                error "${app}: could not rotate SSH key"
                return 1
            }
            did_rotate_keys="true"
            new_key_id=$(_github_add_deploy_key "$owner_repo" "$title" "$pub_key") || new_key_id=""
        fi
        if [[ -z "$new_key_id" || "$new_key_id" == "null" ]]; then
            error "${app}: could not add GitHub deploy key"
            return 1
        fi

        if [[ "$skip_webhook" != "true" ]]; then
            step "Refreshing GitHub webhook..."
            [[ -n "$hook_id" ]] && _github_remove_webhook "$owner_repo" "$hook_id" 2>/dev/null || true
            local extra; extra=$(_github_find_webhook_ids "$owner_repo" "$webhook_url") || true
            local hid
            for hid in $extra; do
                _github_remove_webhook "$owner_repo" "$hid" 2>/dev/null || true
            done
            new_hook_id=$(_github_add_webhook "$owner_repo" "$webhook_url" "$wt") || new_hook_id=""
            if [[ -z "$new_hook_id" || "$new_hook_id" == "null" ]]; then
                error "${app}: could not add GitHub webhook"
                git_save_app_data "$app" "github" "$new_key_id" ""
                return 1
            fi
        fi
    elif [[ "$provider" == "gitlab" ]]; then
        local project_id; project_id=$(_git_parse_gitlab_project "$repository")
        [[ -n "$key_id" ]] && _gitlab_remove_deploy_key "$project_id" "$key_id" 2>/dev/null || true
        _gitlab_remove_deploy_keys_by_title "$project_id" "$title" || true
        new_key_id=$(_gitlab_add_deploy_key "$project_id" "$title" "$pub_key") || new_key_id=""
        if [[ -z "$new_key_id" || "$new_key_id" == "null" ]]; then
            new_key_id=$(_gitlab_find_deploy_key_id "$project_id" "$pub_key") || true
        fi
        if [[ -z "$new_key_id" || "$new_key_id" == "null" ]] && [[ "$did_rotate_keys" != "true" ]]; then
            warn "${app}: deploy key already used on another project — generating a new one"
            pub_key=$(_git_rotate_local_key "$app") || {
                error "${app}: could not rotate SSH key"
                return 1
            }
            did_rotate_keys="true"
            new_key_id=$(_gitlab_add_deploy_key "$project_id" "$title" "$pub_key") || new_key_id=""
        fi
        if [[ -z "$new_key_id" || "$new_key_id" == "null" ]]; then
            error "${app}: could not add GitLab deploy key"
            return 1
        fi

        if [[ "$skip_webhook" != "true" ]]; then
            step "Refreshing GitLab webhook..."
            [[ -n "$hook_id" ]] && _gitlab_remove_webhook "$project_id" "$hook_id" 2>/dev/null || true
            local extra; extra=$(_gitlab_find_webhook_ids "$project_id" "$webhook_url") || true
            local hid
            for hid in $extra; do
                _gitlab_remove_webhook "$project_id" "$hid" 2>/dev/null || true
            done
            new_hook_id=$(_gitlab_add_webhook "$project_id" "$webhook_url" "$wt") || new_hook_id=""
            if [[ -z "$new_hook_id" || "$new_hook_id" == "null" ]]; then
                error "${app}: could not add GitLab webhook"
                git_save_app_data "$app" "gitlab" "$new_key_id" ""
                return 1
            fi
        fi
    else
        error "${app}: unsupported provider ${provider}"
        return 1
    fi

    git_save_app_data "$app" "$provider" "$new_key_id" "${new_hook_id:-}"

    if [[ "$skip_webhook" == "true" ]]; then
        success "${app}: deploy key refreshed (webhook skipped)"
    else
        success "${app}: deploy key + webhook refreshed"
    fi
    return 0
}

# Usage: cipi git refresh [app] [--rotate-keys] [--rotate-secret] [--force]
_git_refresh() {
    parse_args "$@"
    local target="" arg
    for arg in "$@"; do
        [[ "$arg" == --* ]] && continue
        target="$arg"
        break
    done
    local rotate_keys="${ARG_rotate_keys:-}"
    local rotate_secret="${ARG_rotate_secret:-}"

    if [[ -n "$target" ]]; then
        app_exists "$target" || { error "App '${target}' not found"; exit 1; }
        git_refresh_app "$target" "$rotate_keys" "$rotate_secret" || exit 1
        log_action "GIT REFRESH: ${target} rotate_keys=${rotate_keys:-false} rotate_secret=${rotate_secret:-false}"
        cipi_notify \
            "Cipi git refresh: ${target} on $(hostname)" \
            "Deploy key and webhook were re-synced.\n\nServer: $(hostname)\nApp: ${target}\nRotate keys: ${rotate_keys:-false}\nRotate secret: ${rotate_secret:-false}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
            git_configure
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

    if [[ "$rotate_keys" == "true" && "${ARG_force:-}" != "true" ]]; then
        warn "This will generate a NEW SSH deploy key for every git app and re-register it on GitHub/GitLab."
        confirm "Regenerate SSH keys for all apps?" || { info "Cancelled"; return 0; }
    fi
    if [[ "$rotate_secret" == "true" && "${ARG_force:-}" != "true" ]]; then
        warn "This will rotate webhook secrets for every Laravel app."
        confirm "Rotate webhook secrets for all apps?" || { info "Cancelled"; return 0; }
    fi

    echo -e "\n${BOLD}Git refresh${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local ok=0 fail=0
    local app
    while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        if git_refresh_app "$app" "$rotate_keys" "$rotate_secret"; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi
    done <<< "$apps"

    echo ""
    log_action "GIT REFRESH: all apps ok=${ok} fail=${fail} rotate_keys=${rotate_keys:-false} rotate_secret=${rotate_secret:-false}"
    cipi_notify \
        "Cipi git refresh on $(hostname)" \
        "Deploy keys and webhooks were re-synced.\n\nServer: $(hostname)\nSucceeded: ${ok}\nFailed: ${fail}\nRotate keys: ${rotate_keys:-false}\nRotate secret: ${rotate_secret:-false}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        git_configure

    if [[ "$fail" -gt 0 ]]; then
        error "Refresh finished with ${fail} failure(s), ${ok} succeeded"
        exit 1
    fi
    success "Refreshed ${ok} app(s)"
}

# ── CLI COMMANDS ─────────────────────────────────────────────

_git_set_github_token() {
    local token="${1:-}"
    [[ -z "$token" ]] && { error "Usage: cipi git github-token <token>"; exit 1; }
    _git_server_set "github_token" "$token"
    log_action "GIT: GitHub token configured"
    cipi_notify \
        "Cipi GitHub token configured on $(hostname)" \
        "Git provider credentials were updated.\n\nServer: $(hostname)\nProvider: GitHub\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        git_configure
    success "GitHub token saved"
}

_git_set_gitlab_token() {
    local token="${1:-}"
    [[ -z "$token" ]] && { error "Usage: cipi git gitlab-token <token>"; exit 1; }
    _git_server_set "gitlab_token" "$token"
    log_action "GIT: GitLab token configured"
    cipi_notify \
        "Cipi GitLab token configured on $(hostname)" \
        "Git provider credentials were updated.\n\nServer: $(hostname)\nProvider: GitLab\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        git_configure
    success "GitLab token saved"
}

_git_set_gitlab_url() {
    local url="${1:-}"
    [[ -z "$url" ]] && { error "Usage: cipi git gitlab-url <url>"; exit 1; }
    url="${url%/}"
    _git_server_set "gitlab_url" "$url"
    log_action "GIT: GitLab URL set to ${url}"
    cipi_notify \
        "Cipi GitLab URL configured on $(hostname)" \
        "Git provider settings were updated.\n\nServer: $(hostname)\nGitLab URL: ${url}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        git_configure
    success "GitLab URL set to ${url}"
}

_git_remove_github_token() {
    _git_server_remove "github_token"
    log_action "GIT: GitHub token removed"
    cipi_notify \
        "Cipi GitHub token removed on $(hostname)" \
        "Git provider credentials were removed.\n\nServer: $(hostname)\nProvider: GitHub\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        git_configure
    success "GitHub token removed"
}

_git_remove_gitlab_token() {
    _git_server_remove "gitlab_token"
    _git_server_remove "gitlab_url"
    log_action "GIT: GitLab token removed"
    cipi_notify \
        "Cipi GitLab token removed on $(hostname)" \
        "Git provider credentials were removed.\n\nServer: $(hostname)\nProvider: GitLab\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        git_configure
    success "GitLab token and URL removed"
}

_git_status() {
    echo -e "\n${BOLD}Git Provider Integration${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local gh_token; gh_token=$(_git_server_get "github_token")
    if [[ -n "$gh_token" ]]; then
        local masked="${gh_token:0:4}...${gh_token: -4}"
        printf "  %-14s ${GREEN}● connected${NC} (%s)\n" "GitHub" "$masked"
    else
        printf "  %-14s ${DIM}○ not configured${NC}\n" "GitHub"
    fi

    local gl_token; gl_token=$(_git_server_get "gitlab_token")
    if [[ -n "$gl_token" ]]; then
        local masked="${gl_token:0:4}...${gl_token: -4}"
        local gl_url; gl_url=$(_git_server_get "gitlab_url")
        [[ -z "$gl_url" ]] && gl_url="https://gitlab.com"
        printf "  %-14s ${GREEN}● connected${NC} (%s) → %s\n" "GitLab" "$masked" "$gl_url"
    else
        printf "  %-14s ${DIM}○ not configured${NC}\n" "GitLab"
    fi

    # Show apps with git integration
    if [[ -f "${CIPI_CONFIG}/apps.json" ]]; then
        local apps_with_git; apps_with_git=$(vault_read apps.json | jq -r 'to_entries[] | select(.value.git_provider != null) | "\(.key)\t\(.value.git_provider)\t\(.value.git_deploy_key_id // "-")\t\(.value.git_webhook_id // "-")"' 2>/dev/null)
        if [[ -n "$apps_with_git" ]]; then
            echo ""
            printf "  ${BOLD}%-14s %-10s %-14s %s${NC}\n" "APP" "PROVIDER" "DEPLOY KEY" "WEBHOOK"
            echo "  ─────────────────────────────────────────────────"
            echo "$apps_with_git" | while IFS=$'\t' read -r a p dk wh; do
                printf "  %-14s %-10s %-14s %s\n" "$a" "$p" "$dk" "$wh"
            done
        fi
    fi

    echo ""
    echo -e "  ${BOLD}Setup:${NC}"
    echo "    cipi git github-token <token>     Save GitHub PAT"
    echo "    cipi git gitlab-token <token>     Save GitLab PAT"
    echo "    cipi git gitlab-url <url>         Set self-hosted GitLab URL"
    echo "    cipi git remove-github            Remove GitHub token"
    echo "    cipi git remove-gitlab            Remove GitLab token + URL"
    echo "    cipi git refresh [app]            Re-sync deploy keys + webhooks"
    echo "                                      [--rotate-keys] [--rotate-secret]"
    echo ""
}

git_command() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        github-token)   _git_set_github_token "$@" ;;
        gitlab-token)   _git_set_gitlab_token "$@" ;;
        gitlab-url)     _git_set_gitlab_url "$@" ;;
        remove-github)  _git_remove_github_token ;;
        remove-gitlab)  _git_remove_gitlab_token ;;
        refresh)        _git_refresh "$@" ;;
        status|"")      _git_status ;;
        *) error "Unknown: $sub"; echo "Use: github-token gitlab-token gitlab-url remove-github remove-gitlab refresh status"; exit 1 ;;
    esac
}
