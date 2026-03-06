#!/bin/bash
#############################################
# Cipi — Git Provider Integration
# GitHub & GitLab deploy key + webhook automation
#############################################

# ── SERVER.JSON HELPERS ──────────────────────────────────────

_git_server_get() {
    jq -r --arg k "$1" '.[$k] // empty' "${CIPI_CONFIG}/server.json"
}

_git_server_set() {
    local tmp; tmp=$(mktemp)
    jq --arg k "$1" --arg v "$2" '.[$k] = $v' "${CIPI_CONFIG}/server.json" > "$tmp"
    mv "$tmp" "${CIPI_CONFIG}/server.json"; chmod 600 "${CIPI_CONFIG}/server.json"
}

_git_server_remove() {
    local tmp; tmp=$(mktemp)
    jq --arg k "$1" 'del(.[$k])' "${CIPI_CONFIG}/server.json" > "$tmp"
    mv "$tmp" "${CIPI_CONFIG}/server.json"; chmod 600 "${CIPI_CONFIG}/server.json"
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

    local args=(-s -w "\n%{http_code}" -X "$method"
        -H "Accept: application/vnd.github+json"
        -H "Authorization: Bearer ${token}"
        -H "X-GitHub-Api-Version: 2022-11-28")
    [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" -d "$data")

    curl "${args[@]}" "https://api.github.com${endpoint}"
}

_github_add_deploy_key() {
    local owner_repo="$1" title="$2" pub_key="$3"
    local payload; payload=$(jq -n --arg t "$title" --arg k "$pub_key" '{title: $t, key: $k, read_only: true}')
    local resp; resp=$(_github_api POST "/repos/${owner_repo}/keys" "$payload")
    local code; code=$(echo "$resp" | tail -1)
    local body; body=$(echo "$resp" | sed '$d')

    if [[ "$code" == "201" ]]; then
        echo "$body" | jq -r '.id'
        return 0
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

    local args=(-s -w "\n%{http_code}" -X "$method"
        -H "PRIVATE-TOKEN: ${token}")
    [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" -d "$data")

    curl "${args[@]}" "${base_url}/api/v4${endpoint}"
}

_gitlab_add_deploy_key() {
    local project_id="$1" title="$2" pub_key="$3"
    local payload; payload=$(jq -n --arg t "$title" --arg k "$pub_key" '{title: $t, key: $k, can_push: false}')
    local resp; resp=$(_gitlab_api POST "/projects/${project_id}/deploy_keys" "$payload")
    local code; code=$(echo "$resp" | tail -1)
    local body; body=$(echo "$resp" | sed '$d')

    if [[ "$code" == "201" ]]; then
        echo "$body" | jq -r '.id'
        return 0
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
git_setup_repo() {
    local app="$1" repository="$2" domain="$3" webhook_token="$4" pub_key="$5"
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
    local webhook_url="https://${domain}/cipi/webhook"

    step "Configuring ${provider} integration..."

    if [[ "$provider" == "github" ]]; then
        local owner_repo; owner_repo=$(_git_parse_github_repo "$repository")
        GIT_DEPLOY_KEY_ID=$(_github_add_deploy_key "$owner_repo" "cipi:${app}" "$pub_key" 2>&1) || {
            warn "Could not add deploy key to GitHub — add it manually"
            GIT_DEPLOY_KEY_ID=""
        }
        GIT_WEBHOOK_ID=$(_github_add_webhook "$owner_repo" "$webhook_url" "$webhook_token" 2>&1) || {
            warn "Could not add webhook to GitHub — add it manually"
            GIT_WEBHOOK_ID=""
        }
    elif [[ "$provider" == "gitlab" ]]; then
        local project_id; project_id=$(_git_parse_gitlab_project "$repository")
        GIT_DEPLOY_KEY_ID=$(_gitlab_add_deploy_key "$project_id" "cipi:${app}" "$pub_key" 2>&1) || {
            warn "Could not add deploy key to GitLab — add it manually"
            GIT_DEPLOY_KEY_ID=""
        }
        GIT_WEBHOOK_ID=$(_gitlab_add_webhook "$project_id" "$webhook_url" "$webhook_token" 2>&1) || {
            warn "Could not add webhook to GitLab — add it manually"
            GIT_WEBHOOK_ID=""
        }
    fi

    if [[ -n "$GIT_DEPLOY_KEY_ID" && -n "$GIT_WEBHOOK_ID" ]]; then
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
        local tmp; tmp=$(mktemp)
        jq --arg a "$app" --argjson v "$key_id" '.[$a].git_deploy_key_id = $v' "${CIPI_CONFIG}/apps.json" > "$tmp"
        mv "$tmp" "${CIPI_CONFIG}/apps.json"; chmod 600 "${CIPI_CONFIG}/apps.json"
        ensure_apps_json_api_access
    fi
    if [[ -n "$hook_id" ]]; then
        local tmp; tmp=$(mktemp)
        jq --arg a "$app" --argjson v "$hook_id" '.[$a].git_webhook_id = $v' "${CIPI_CONFIG}/apps.json" > "$tmp"
        mv "$tmp" "${CIPI_CONFIG}/apps.json"; chmod 600 "${CIPI_CONFIG}/apps.json"
        ensure_apps_json_api_access
    fi
}

# Remove git integration data from apps.json
git_clear_app_data() {
    local app="$1"
    local tmp; tmp=$(mktemp)
    jq --arg a "$app" 'del(.[$a].git_provider, .[$a].git_deploy_key_id, .[$a].git_webhook_id)' "${CIPI_CONFIG}/apps.json" > "$tmp"
    mv "$tmp" "${CIPI_CONFIG}/apps.json"; chmod 600 "${CIPI_CONFIG}/apps.json"
    ensure_apps_json_api_access
}

# ── CLI COMMANDS ─────────────────────────────────────────────

_git_set_github_token() {
    local token="${1:-}"
    [[ -z "$token" ]] && { error "Usage: cipi git github-token <token>"; exit 1; }
    _git_server_set "github_token" "$token"
    log_action "GIT: GitHub token configured"
    success "GitHub token saved"
}

_git_set_gitlab_token() {
    local token="${1:-}"
    [[ -z "$token" ]] && { error "Usage: cipi git gitlab-token <token>"; exit 1; }
    _git_server_set "gitlab_token" "$token"
    log_action "GIT: GitLab token configured"
    success "GitLab token saved"
}

_git_set_gitlab_url() {
    local url="${1:-}"
    [[ -z "$url" ]] && { error "Usage: cipi git gitlab-url <url>"; exit 1; }
    url="${url%/}"
    _git_server_set "gitlab_url" "$url"
    log_action "GIT: GitLab URL set to ${url}"
    success "GitLab URL set to ${url}"
}

_git_remove_github_token() {
    _git_server_remove "github_token"
    log_action "GIT: GitHub token removed"
    success "GitHub token removed"
}

_git_remove_gitlab_token() {
    _git_server_remove "gitlab_token"
    _git_server_remove "gitlab_url"
    log_action "GIT: GitLab token removed"
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
        local apps_with_git; apps_with_git=$(jq -r 'to_entries[] | select(.value.git_provider != null) | "\(.key)\t\(.value.git_provider)\t\(.value.git_deploy_key_id // "-")\t\(.value.git_webhook_id // "-")"' "${CIPI_CONFIG}/apps.json" 2>/dev/null)
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
        status|"")      _git_status ;;
        *) error "Unknown: $sub"; echo "Use: github-token gitlab-token gitlab-url remove-github remove-gitlab status"; exit 1 ;;
    esac
}
