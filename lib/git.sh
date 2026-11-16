#!/bin/bash
#############################################
# Cipi — Git Provider Integration
# Deploy key + webhook automation for GitHub, GitLab,
# Cursor Origin, Bitbucket, Azure DevOps, and AWS CodeCommit.
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

# Numeric IDs stay numbers in apps.json; UUIDs / APKA keys stay strings.
_git_app_set_id() {
    local app="$1" field="$2" value="$3"
    [[ -z "$value" || "$value" == "null" ]] && return 0
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        vault_read apps.json | jq --arg a "$app" --arg f "$field" --argjson v "$value" '.[$a][$f] = $v' | vault_write apps.json
    else
        vault_read apps.json | jq --arg a "$app" --arg f "$field" --arg v "$value" '.[$a][$f] = $v' | vault_write apps.json
    fi
    ensure_apps_json_api_access
}

_git_urlencode() {
    jq -sRr @uri <<< "$1" | sed 's/%0A$//'
}

# Host of a git remote (git@host:path, ssh://[user@]host/path, https://host/path).
_git_url_host() {
    local url="$1"
    if [[ "$url" =~ ^git@([^:]+): ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ "$url" =~ ^ssh://([^/]+) ]]; then
        local h="${BASH_REMATCH[1]}"
        h="${h##*@}"
        h="${h%%:*}"
        printf '%s\n' "$h"
    elif [[ "$url" =~ ^https?://([^/]+) ]]; then
        local h="${BASH_REMATCH[1]}"
        h="${h##*@}"
        h="${h%%:*}"
        printf '%s\n' "$h"
    fi
}

# Seed known_hosts for localhost plus every host this app will SSH to.
git_seed_app_known_hosts() {
    local dest="$1" repository="${2:-}"
    local hosts=(localhost 127.0.0.1 github.com gitlab.com bitbucket.org origin.cursor.com ssh.dev.azure.com)
    local h; h=$(_git_url_host "$repository")
    [[ -n "$h" ]] && hosts+=("$h")
    local seen="" host
    for host in "${hosts[@]}"; do
        [[ -z "$host" ]] && continue
        [[ " $seen " == *" $host "* ]] && continue
        seen+=" $host"
        if grep -qE "(^|[,[:space:]])${host}[,[:space:]]" "$dest" 2>/dev/null; then
            continue
        fi
        ssh-keyscan -T 5 -H "$host" >> "$dest" 2>/dev/null || true
    done
}

# ── DETECT PROVIDER ──────────────────────────────────────────

# Returns: github, gitlab, origin, bitbucket, azure, codecommit, or empty
_git_detect_provider() {
    local url="$1"
    if [[ "$url" == *"github.com"* ]]; then
        echo "github"
    elif [[ "$url" == *"origin.cursor.com"* || "$url" == *"cursor.com/codebase"* ]]; then
        echo "origin"
    elif [[ "$url" == *"bitbucket.org"* ]]; then
        echo "bitbucket"
    elif [[ "$url" == *"git-codecommit."* && "$url" == *".amazonaws.com"* ]]; then
        echo "codecommit"
    elif [[ "$url" == *"dev.azure.com"* || "$url" == *"visualstudio.com"* || "$url" == *"ssh.dev.azure.com"* ]]; then
        echo "azure"
    elif [[ "$url" == *"gitlab"* ]]; then
        echo "gitlab"
    fi
}

_git_provider_ready() {
    local provider="$1"
    case "$provider" in
        codecommit)
            [[ -n "$(_git_server_get codecommit_access_key)" \
            && -n "$(_git_server_get codecommit_secret_key)" \
            && -n "$(_git_server_get codecommit_iam_user)" ]]
            ;;
        *)
            [[ -n "$(_git_server_get "${provider}_token")" ]]
            ;;
    esac
}

_git_provider_webhooks() {
    case "$1" in
        github|gitlab|bitbucket|azure) return 0 ;;
        *) return 1 ;;
    esac
}

_git_token_hint() {
    case "$1" in
        codecommit) echo "cipi git codecommit-token <access-key> <secret-key> <iam-user>" ;;
        *) echo "cipi git ${1}-token <token>" ;;
    esac
}

_git_provider_label() {
    case "$1" in
        github) echo "GitHub" ;;
        gitlab) echo "GitLab" ;;
        origin) echo "Origin" ;;
        bitbucket) echo "Bitbucket" ;;
        azure) echo "Azure DevOps" ;;
        codecommit) echo "CodeCommit" ;;
        *) echo "$1" ;;
    esac
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

# Origin: git@origin.cursor.com:owner/repo.git → owner/repo
_git_parse_origin_repo() {
    echo "$1" | sed -E \
        's|.*origin\.cursor\.com[:/](.+)\.git$|\1|; s|.*origin\.cursor\.com[:/](.+)$|\1|; s|.*cursor\.com/codebase/(.+)\.git$|\1|; s|.*cursor\.com/codebase/(.+)$|\1|'
}

# Bitbucket Cloud: git@bitbucket.org:workspace/repo.git → workspace/repo
_git_parse_bitbucket_repo() {
    echo "$1" | sed -E 's|.*bitbucket\.org[:/](.+)\.git$|\1|; s|.*bitbucket\.org[:/](.+)$|\1|'
}

# Azure DevOps: org/project/repo
_git_parse_azure_repo() {
    local url="$1"
    if [[ "$url" == *"ssh.dev.azure.com"* ]]; then
        echo "$url" | sed -E 's|.*ssh\.dev\.azure\.com:v3/||; s|\.git$||'
        return 0
    fi
    if [[ "$url" == *".visualstudio.com"* ]]; then
        local org path
        org=$(echo "$url" | sed -nE 's|https?://([^.]+)\.visualstudio\.com.*|\1|p')
        path=$(echo "$url" | sed -E 's|https?://[^/]+/||; s|\.git$||')
        path="${path#DefaultCollection/}"
        path="${path//_git\//}"
        echo "${org}/${path}"
        return 0
    fi
    echo "$url" | sed -E 's|.*dev\.azure\.com/||; s|/_git/|/|; s|\.git$||'
}

_azure_org()     { echo "$1" | cut -d/ -f1; }
_azure_project() { echo "$1" | cut -d/ -f2; }
_azure_repo()    { echo "$1" | cut -d/ -f3-; }

# CodeCommit: region/reponame
_git_parse_codecommit_repo() {
    local region repo
    region=$(echo "$1" | sed -nE 's|.*git-codecommit\.([a-z0-9-]+)\.amazonaws\.com.*|\1|p')
    repo=$(echo "$1" | sed -nE 's|.*/v1/repos/([^./]+).*|\1|p')
    echo "${region}/${repo}"
}

_codecommit_region() { echo "$1" | cut -d/ -f1; }
_codecommit_repo()   { echo "$1" | cut -d/ -f2-; }

_git_parse_repo() {
    case "$1" in
        github)     _git_parse_github_repo "$2" ;;
        gitlab)     _git_parse_gitlab_project "$2" ;;
        origin)     _git_parse_origin_repo "$2" ;;
        bitbucket)  _git_parse_bitbucket_repo "$2" ;;
        azure)      _git_parse_azure_repo "$2" ;;
        codecommit) _git_parse_codecommit_repo "$2" ;;
    esac
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

# ── Why a forge refused a call ───────────────────────────────
# A bare "HTTP 404: Not Found" sent people looking for a missing repository
# when the token was the problem: GitHub answers 404, not 403, to a token
# that may not see or administer a repository.
_github_access_hint() {
    echo "check the repository name in the app's repository URL, then the token: a fine-grained token must list the repository under 'Repository access' with 'Administration: Read and write' (deploy keys) and 'Webhooks: Read and write'; a classic token needs the 'repo' and 'admin:repo_hook' scopes. Save a new one with: cipi git github-token <token>"
}
_gitlab_access_hint() {
    echo "check the project path in the app's repository URL, then the token: it needs the 'api' scope and the Maintainer role on the project. Save a new one with: cipi git gitlab-token <token>"
}
_bitbucket_access_hint() {
    echo "check the workspace/repository in the app's repository URL, then the token: it needs 'Repositories: Admin' (deploy keys) and 'Webhooks: Read and write'. Save a new one with: cipi git bitbucket-token <token>"
}

# One line per failed call: what, where, the HTTP code, and what it means.
# Usage: _git_api_fail <github|gitlab|bitbucket> <what> <repo> <code> <body>
_git_api_fail() {
    local provider="$1" what="$2" repo="$3" code="$4" body="$5" label msg hint
    label=$(_git_provider_label "$provider")
    msg=$(printf '%s' "$body" | jq -r '.error.message // .message // empty' 2>/dev/null | head -1)
    hint=$("_${provider}_access_hint")
    case "$code" in
        404) error "${label} ${what} failed (HTTP 404): '${repo}' is not visible to the saved token — ${hint}" ;;
        403) error "${label} ${what} failed (HTTP 403): ${msg:-forbidden} — ${hint}" ;;
        401) error "${label} ${what} failed (HTTP 401): the saved token was rejected (revoked or expired) — save a new one: cipi git ${provider}-token <token>" ;;
        ""|000) error "${label} ${what} failed: no answer from the API (network, DNS or a missing token)" ;;
        *)   error "${label} ${what} failed (HTTP ${code}): ${msg:-no message}" ;;
    esac
}

# Can the saved token see the repository at all? Decides, after a refused
# deploy key, between "this key already hangs on another repository" (rotate
# it) and "the token cannot reach the repository" (rotating would only lose
# the key that works). 0 = visible, 1 = not visible (GIT_REPO_VISIBLE_CODE
# holds the HTTP code), 2 = no way to tell for this provider.
GIT_REPO_VISIBLE_CODE=""
_git_repo_visible() {
    local provider="$1" repo="$2" resp="" code
    case "$provider" in
        github)    resp=$(_github_api GET "/repos/${repo}") || resp="" ;;
        gitlab)    resp=$(_gitlab_api GET "/projects/${repo}") || resp="" ;;
        bitbucket) resp=$(_bitbucket_api GET "/repositories/$(_bitbucket_ws_repo "$repo")") || resp="" ;;
        *) return 2 ;;
    esac
    code=$(_git_http_code "$resp")
    GIT_REPO_VISIBLE_CODE="${code:-000}"
    [[ "$code" == "200" ]]
}

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
    _git_api_fail github "deploy key" "$owner_repo" "$code" "$body"
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
    _git_api_fail github "webhook" "$owner_repo" "$code" "$body"
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
    _git_api_fail gitlab "deploy key" "${project_id//%2F//}" "$code" "$body"
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
    _git_api_fail gitlab "webhook" "${project_id//%2F//}" "$code" "$body"
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

# ── ORIGIN API (Cursor) ──────────────────────────────────────
# SSH keys are account-scoped (same as Azure). Per-repo webhooks do not
# exist — Origin Apps have a single webhook URL signed with Ed25519, not HMAC.
# Token: Cursor API key / CURSOR_AUTH_TOKEN (Bearer).

_origin_api() {
    local method="$1" endpoint="$2" data="${3:-}"
    local token; token=$(_git_server_get "origin_token")
    [[ -z "$token" ]] && return 1

    local args=(-sS --connect-timeout 10 --max-time 30 -w "\n%{http_code}" -X "$method"
        -H "Accept: application/json"
        -H "Authorization: Bearer ${token}")
    [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" -d "$data")

    curl "${args[@]}" "https://api.cursor.com/v1/origin${endpoint}"
}

_origin_try() {
    local method="$1" data="${2:-}"
    local ep resp code
    for ep in /user/ssh-keys /ssh-keys /user/keys; do
        resp=$(_origin_api "$method" "$ep" "$data") || true
        code=$(_git_http_code "$resp")
        case "$code" in
            200|201) printf '%s\n' "$resp"; return 0 ;;
            401|403)
                error "Origin token rejected (HTTP ${code}) — update with: cipi git origin-token <token>"
                return 1 ;;
        esac
    done
    printf '%s\n' "${resp:-}"
    return 1
}

_origin_get_keys() {
    local resp; resp=$(_origin_try GET) || return 1
    _git_http_body "$resp"
}

_origin_find_ssh_key_id() {
    local pub_key="$1"
    local blob; blob=$(_git_key_blob "$pub_key")
    [[ -z "$blob" ]] && return 1
    local keys; keys=$(_origin_get_keys) || return 1
    echo "$keys" | jq -r --arg b "$blob" '
        (if type == "array" then . else (.keys // .items // .sshKeys // []) end)
        | [.[] | select(((.key // .publicKey // .keyData // "") | split(" ") | (.[0] + " " + .[1])) == $b)
            | (.id // .keyId // .sshKeyId // empty)] | first // empty'
}

_origin_remove_ssh_keys_by_title() {
    local title="$1"
    local keys; keys=$(_origin_get_keys) || return 0
    local ids
    ids=$(echo "$keys" | jq -r --arg t "$title" '
        (if type == "array" then . else (.keys // .items // .sshKeys // []) end)
        | .[] | select((.title // .name // .friendlyName // "") == $t) | (.id // .keyId // .sshKeyId // empty)')
    local id
    for id in $ids; do
        _origin_remove_ssh_key "$id" 2>/dev/null || true
    done
}

_origin_add_ssh_key() {
    local title="$1" pub_key="$2"
    local payload; payload=$(jq -n --arg t "$title" --arg k "$pub_key" \
        '{title: $t, name: $t, key: $k, publicKey: $k}')
    local resp; resp=$(_origin_try POST "$payload") || true
    local code; code=$(_git_http_code "$resp")
    local body; body=$(_git_http_body "$resp")

    if [[ "$code" == "201" || "$code" == "200" ]]; then
        echo "$body" | jq -r '.id // .keyId // .sshKeyId // empty'
        return 0
    fi
    if [[ "$code" == "400" || "$code" == "409" || "$code" == "422" ]]; then
        local existing; existing=$(_origin_find_ssh_key_id "$pub_key") || true
        if [[ -n "$existing" && "$existing" != "null" ]]; then
            echo "$existing"
            return 0
        fi
    fi
    error "Origin SSH key failed (HTTP ${code:-?}): $(echo "$body" | jq -r '.message // .error // empty')"
    return 1
}

_origin_remove_ssh_key() {
    local key_id="$1"
    [[ -z "$key_id" || "$key_id" == "null" ]] && return 0
    local ep resp code
    for ep in "/user/ssh-keys/${key_id}" "/ssh-keys/${key_id}" "/user/keys/${key_id}"; do
        resp=$(_origin_api DELETE "$ep") || true
        code=$(_git_http_code "$resp")
        [[ "$code" == "204" || "$code" == "200" || "$code" == "404" ]] && return 0
    done
    warn "Origin remove SSH key: HTTP ${code:-?}"
    return 1
}

# ── BITBUCKET CLOUD API ──────────────────────────────────────

_bitbucket_api() {
    local method="$1" endpoint="$2" data="${3:-}"
    local token; token=$(_git_server_get "bitbucket_token")
    [[ -z "$token" ]] && return 1

    local args=(-sS --connect-timeout 10 --max-time 30 -w "\n%{http_code}" -X "$method"
        -H "Accept: application/json")
    if [[ "$token" == *:* ]]; then
        args+=(-u "$token")
    else
        args+=(-H "Authorization: Bearer ${token}")
    fi
    [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" -d "$data")

    curl "${args[@]}" "https://api.bitbucket.org/2.0${endpoint}"
}

_bitbucket_get_json() {
    local endpoint="$1"
    local resp; resp=$(_bitbucket_api GET "$endpoint") || true
    local code; code=$(_git_http_code "$resp")
    local body; body=$(_git_http_body "$resp")
    case "$code" in
        200) printf '%s\n' "$body"; return 0 ;;
        401|403)
            error "Bitbucket token rejected (HTTP ${code}) — update with: cipi git bitbucket-token <token>"
            return 1 ;;
        *) return 1 ;;
    esac
}

_bitbucket_ws_repo() {
    local workspace repo
    workspace=$(echo "$1" | cut -d/ -f1)
    repo=$(echo "$1" | cut -d/ -f2-)
    echo "$(_git_urlencode "$workspace")/$(_git_urlencode "$repo")"
}

_bitbucket_find_deploy_key_id() {
    local owner_repo="$1" pub_key="$2"
    local blob; blob=$(_git_key_blob "$pub_key")
    [[ -z "$blob" ]] && return 1
    local path; path=$(_bitbucket_ws_repo "$owner_repo")
    local keys; keys=$(_bitbucket_get_json "/repositories/${path}/deploy-keys?pagelen=100") || return 1
    echo "$keys" | jq -r --arg b "$blob" \
        '[.values[]? | select((.key | split(" ") | (.[0] + " " + .[1])) == $b) | .id] | first // empty'
}

_bitbucket_find_webhook_ids() {
    local owner_repo="$1" webhook_url="$2"
    local path; path=$(_bitbucket_ws_repo "$owner_repo")
    local hooks; hooks=$(_bitbucket_get_json "/repositories/${path}/hooks?pagelen=100") || return 1
    echo "$hooks" | jq -r --arg u "$webhook_url" '.values[]? | select(.url == $u) | .uuid'
}

_bitbucket_remove_deploy_keys_by_title() {
    local owner_repo="$1" title="$2"
    local path; path=$(_bitbucket_ws_repo "$owner_repo")
    local keys; keys=$(_bitbucket_get_json "/repositories/${path}/deploy-keys?pagelen=100") || return 0
    local ids; ids=$(echo "$keys" | jq -r --arg t "$title" '.values[]? | select(.label == $t) | .id')
    local id
    for id in $ids; do
        _bitbucket_remove_deploy_key "$owner_repo" "$id" 2>/dev/null || true
    done
}

_bitbucket_add_deploy_key() {
    local owner_repo="$1" title="$2" pub_key="$3"
    local path; path=$(_bitbucket_ws_repo "$owner_repo")
    local payload; payload=$(jq -n --arg t "$title" --arg k "$pub_key" '{label: $t, key: $k}')
    local resp; resp=$(_bitbucket_api POST "/repositories/${path}/deploy-keys" "$payload")
    local code; code=$(_git_http_code "$resp")
    local body; body=$(_git_http_body "$resp")

    if [[ "$code" == "201" || "$code" == "200" ]]; then
        echo "$body" | jq -r '.id'
        return 0
    fi
    if [[ "$code" == "400" || "$code" == "409" || "$code" == "422" ]]; then
        local existing; existing=$(_bitbucket_find_deploy_key_id "$owner_repo" "$pub_key") || true
        if [[ -n "$existing" && "$existing" != "null" ]]; then
            echo "$existing"
            return 0
        fi
    fi
    _git_api_fail bitbucket "deploy key" "$owner_repo" "$code" "$body"
    return 1
}

_bitbucket_remove_deploy_key() {
    local owner_repo="$1" key_id="$2"
    [[ -z "$key_id" || "$key_id" == "null" ]] && return 0
    local path; path=$(_bitbucket_ws_repo "$owner_repo")
    local resp; resp=$(_bitbucket_api DELETE "/repositories/${path}/deploy-keys/${key_id}")
    local code; code=$(_git_http_code "$resp")
    [[ "$code" == "204" || "$code" == "200" || "$code" == "404" ]] && return 0
    warn "Bitbucket remove deploy key: HTTP ${code}"
    return 1
}

_bitbucket_add_webhook() {
    local owner_repo="$1" webhook_url="$2" secret="$3"
    local path; path=$(_bitbucket_ws_repo "$owner_repo")
    local payload; payload=$(jq -n --arg u "$webhook_url" --arg s "$secret" \
        '{description: "cipi", url: $u, active: true, secret: $s, events: ["repo:push"]}')
    local resp; resp=$(_bitbucket_api POST "/repositories/${path}/hooks" "$payload")
    local code; code=$(_git_http_code "$resp")
    local body; body=$(_git_http_body "$resp")

    if [[ "$code" == "201" || "$code" == "200" ]]; then
        echo "$body" | jq -r '.uuid'
        return 0
    fi
    _git_api_fail bitbucket "webhook" "$owner_repo" "$code" "$body"
    return 1
}

_bitbucket_remove_webhook() {
    local owner_repo="$1" hook_id="$2"
    [[ -z "$hook_id" || "$hook_id" == "null" ]] && return 0
    local path; path=$(_bitbucket_ws_repo "$owner_repo")
    local enc; enc=$(_git_urlencode "$hook_id")
    local resp; resp=$(_bitbucket_api DELETE "/repositories/${path}/hooks/${enc}")
    local code; code=$(_git_http_code "$resp")
    [[ "$code" == "204" || "$code" == "200" || "$code" == "404" ]] && return 0
    warn "Bitbucket remove webhook: HTTP ${code}"
    return 1
}

# ── AZURE DEVOPS API ─────────────────────────────────────────
# SSH keys are account-scoped. Service hooks are per project/repo.
# PAT via Basic empty-user (:PAT). Webhook secret is sent as X-Gitlab-Token
# so cipi/agent can verify it the same way as GitLab.

_azure_auth_header() {
    local token; token=$(_git_server_get "azure_token")
    [[ -z "$token" ]] && return 1
    printf 'Authorization: Basic %s' "$(printf ':%s' "$token" | base64 | tr -d '\n')"
}

_azure_api() {
    local method="$1" url="$2" data="${3:-}"
    local auth; auth=$(_azure_auth_header) || return 1
    local args=(-sS --connect-timeout 10 --max-time 30 -w "\n%{http_code}" -X "$method"
        -H "Accept: application/json"
        -H "$auth")
    [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" -d "$data")
    curl "${args[@]}" "$url"
}

_azure_get_json() {
    local url="$1"
    local resp; resp=$(_azure_api GET "$url") || true
    local code; code=$(_git_http_code "$resp")
    local body; body=$(_git_http_body "$resp")
    case "$code" in
        200) printf '%s\n' "$body"; return 0 ;;
        401|403)
            error "Azure DevOps token rejected (HTTP ${code}) — update with: cipi git azure-token <PAT>"
            return 1 ;;
        *) return 1 ;;
    esac
}

_azure_resolve_ids() {
    local parsed="$1"
    local org project repo
    org=$(_azure_org "$parsed")
    project=$(_azure_project "$parsed")
    repo=$(_azure_repo "$parsed")
    [[ -z "$org" || -z "$project" || -z "$repo" ]] && return 1
    local enc_org enc_project enc_repo
    enc_org=$(_git_urlencode "$org")
    enc_project=$(_git_urlencode "$project")
    enc_repo=$(_git_urlencode "$repo")
    local proj; proj=$(_azure_get_json "https://dev.azure.com/${enc_org}/_apis/projects/${enc_project}?api-version=7.1") || return 1
    local project_id; project_id=$(echo "$proj" | jq -r '.id // empty')
    local rinfo; rinfo=$(_azure_get_json "https://dev.azure.com/${enc_org}/${enc_project}/_apis/git/repositories/${enc_repo}?api-version=7.1") || return 1
    local repo_id; repo_id=$(echo "$rinfo" | jq -r '.id // empty')
    [[ -z "$project_id" || -z "$repo_id" ]] && return 1
    printf '%s %s %s\n' "$org" "$project_id" "$repo_id"
}

_azure_find_ssh_key_id() {
    local parsed="$1" pub_key="$2"
    local org; org=$(_azure_org "$parsed")
    local blob; blob=$(_git_key_blob "$pub_key")
    [[ -z "$org" || -z "$blob" ]] && return 1
    local enc; enc=$(_git_urlencode "$org")
    local keys; keys=$(_azure_get_json "https://vssps.dev.azure.com/${enc}/_apis/ssh/publickeys?api-version=7.1-preview.1") || return 1
    echo "$keys" | jq -r --arg b "$blob" \
        '[.value[]? | select(((.keyData // .publicKey // "") | split(" ") | (.[0] + " " + .[1])) == $b) | (.keyId // .id // empty)] | first // empty'
}

_azure_find_webhook_ids() {
    local parsed="$1" webhook_url="$2"
    local org; org=$(_azure_org "$parsed")
    local enc; enc=$(_git_urlencode "$org")
    local hooks; hooks=$(_azure_get_json "https://dev.azure.com/${enc}/_apis/hooks/subscriptions?api-version=7.1") || return 1
    echo "$hooks" | jq -r --arg u "$webhook_url" \
        '.value[]? | select(.consumerInputs.url == $u) | .id'
}

_azure_remove_ssh_keys_by_title() {
    local parsed="$1" title="$2"
    local org; org=$(_azure_org "$parsed")
    local enc; enc=$(_git_urlencode "$org")
    local keys; keys=$(_azure_get_json "https://vssps.dev.azure.com/${enc}/_apis/ssh/publickeys?api-version=7.1-preview.1") || return 0
    local ids; ids=$(echo "$keys" | jq -r --arg t "$title" \
        '.value[]? | select((.friendlyName // .displayName // "") == $t) | (.keyId // .id // empty)')
    local id
    for id in $ids; do
        _azure_remove_ssh_key "$parsed" "$id" 2>/dev/null || true
    done
}

_azure_add_ssh_key() {
    local parsed="$1" title="$2" pub_key="$3"
    local org; org=$(_azure_org "$parsed")
    local enc; enc=$(_git_urlencode "$org")
    local payload; payload=$(jq -n --arg t "$title" --arg k "$pub_key" '{friendlyName: $t, keyData: $k}')
    local resp; resp=$(_azure_api POST "https://vssps.dev.azure.com/${enc}/_apis/ssh/publickeys?api-version=7.1-preview.1" "$payload")
    local code; code=$(_git_http_code "$resp")
    local body; body=$(_git_http_body "$resp")

    if [[ "$code" == "201" || "$code" == "200" ]]; then
        echo "$body" | jq -r '.keyId // .id // empty'
        return 0
    fi
    if [[ "$code" == "400" || "$code" == "409" || "$code" == "422" ]]; then
        local existing; existing=$(_azure_find_ssh_key_id "$parsed" "$pub_key") || true
        if [[ -n "$existing" && "$existing" != "null" ]]; then
            echo "$existing"
            return 0
        fi
    fi
    error "Azure DevOps SSH key failed (HTTP ${code}): $(echo "$body" | jq -r '.message // empty')"
    return 1
}

_azure_remove_ssh_key() {
    local parsed="$1" key_id="$2"
    [[ -z "$key_id" || "$key_id" == "null" ]] && return 0
    local org; org=$(_azure_org "$parsed")
    local enc; enc=$(_git_urlencode "$org")
    local kid; kid=$(_git_urlencode "$key_id")
    local resp; resp=$(_azure_api DELETE "https://vssps.dev.azure.com/${enc}/_apis/ssh/publickeys/${kid}?api-version=7.1-preview.1")
    local code; code=$(_git_http_code "$resp")
    [[ "$code" == "204" || "$code" == "200" || "$code" == "404" ]] && return 0
    warn "Azure DevOps remove SSH key: HTTP ${code}"
    return 1
}

_azure_add_webhook() {
    local parsed="$1" webhook_url="$2" secret="$3"
    local ids; ids=$(_azure_resolve_ids "$parsed") || {
        error "Azure DevOps: could not resolve project/repository from ${parsed}"
        return 1
    }
    local org project_id repo_id
    read -r org project_id repo_id <<< "$ids"
    local enc; enc=$(_git_urlencode "$org")
    local payload
    payload=$(jq -n --arg url "$webhook_url" --arg secret "$secret" \
        --arg projectId "$project_id" --arg repository "$repo_id" \
        '{
            publisherId: "tfs",
            eventType: "git.push",
            resourceVersion: "1.0",
            consumerId: "webHooks",
            consumerActionId: "httpRequest",
            publisherInputs: {projectId: $projectId, repository: $repository},
            consumerInputs: {url: $url, httpHeaders: ("X-Gitlab-Token:" + $secret)}
        }')
    local resp; resp=$(_azure_api POST "https://dev.azure.com/${enc}/_apis/hooks/subscriptions?api-version=7.1" "$payload")
    local code; code=$(_git_http_code "$resp")
    local body; body=$(_git_http_body "$resp")
    if [[ "$code" == "200" || "$code" == "201" ]]; then
        echo "$body" | jq -r '.id // empty'
        return 0
    fi
    error "Azure DevOps webhook failed (HTTP ${code}): $(echo "$body" | jq -r '.message // empty')"
    return 1
}

_azure_remove_webhook() {
    local parsed="$1" hook_id="$2"
    [[ -z "$hook_id" || "$hook_id" == "null" ]] && return 0
    local org; org=$(_azure_org "$parsed")
    local enc; enc=$(_git_urlencode "$org")
    local hid; hid=$(_git_urlencode "$hook_id")
    local resp; resp=$(_azure_api DELETE "https://dev.azure.com/${enc}/_apis/hooks/subscriptions/${hid}?api-version=7.1")
    local code; code=$(_git_http_code "$resp")
    [[ "$code" == "204" || "$code" == "200" || "$code" == "404" ]] && return 0
    warn "Azure DevOps remove webhook: HTTP ${code}"
    return 1
}

# ── AWS CODECOMMIT (IAM SSH keys) ────────────────────────────
# No HTTP webhooks (SNS/EventBridge only). SSH keys live on an IAM user
# (max 5). After upload the SSH Key ID must be the SSH username.

_codecommit_iam() {
    local action="$1"
    shift
    local ak sk
    ak=$(_git_server_get "codecommit_access_key")
    sk=$(_git_server_get "codecommit_secret_key")
    [[ -z "$ak" || -z "$sk" ]] && return 1
    if ! curl --help 2>/dev/null | grep -q aws-sigv4; then
        error "curl is too old for AWS SigV4 (need 7.75+) — cannot talk to IAM"
        return 1
    fi
    local args=(-sS --connect-timeout 10 --max-time 30 -w "\n%{http_code}"
        --aws-sigv4 "aws:amz:us-east-1:iam"
        -u "${ak}:${sk}"
        -X POST "https://iam.amazonaws.com/"
        -H "Content-Type: application/x-www-form-urlencoded; charset=utf-8"
        --data-urlencode "Action=${action}"
        --data-urlencode "Version=2010-05-08")
    local kv
    for kv in "$@"; do
        args+=(--data-urlencode "$kv")
    done
    curl "${args[@]}"
}

_codecommit_xml_tag() {
    local tag="$1" xml="$2"
    echo "$xml" | grep -oE "<${tag}>[^<]+" | sed "s/<${tag}>//" | head -1
}

_codecommit_find_key_id() {
    local pub_key="$1"
    local user; user=$(_git_server_get "codecommit_iam_user")
    [[ -z "$user" ]] && return 1
    local resp; resp=$(_codecommit_iam ListSSHPublicKeys "UserName=${user}") || return 1
    local code; code=$(_git_http_code "$resp")
    local body; body=$(_git_http_body "$resp")
    [[ "$code" != "200" ]] && return 1
    local ids; ids=$(echo "$body" | grep -oE '<SSHPublicKeyId>[^<]+' | sed 's/<SSHPublicKeyId>//')
    local id got blob
    blob=$(_git_key_blob "$pub_key")
    for id in $ids; do
        got=$(_codecommit_iam GetSSHPublicKey "UserName=${user}" "SSHPublicKeyId=${id}") || continue
        [[ "$(_git_http_code "$got")" == "200" ]] || continue
        echo "$(_git_http_body "$got")" | grep -qF "$blob" && { echo "$id"; return 0; }
    done
    return 1
}

_codecommit_add_ssh_key() {
    local pub_key="$1"
    local user; user=$(_git_server_get "codecommit_iam_user")
    [[ -z "$user" ]] && { error "No CodeCommit IAM user — set with: cipi git codecommit-token"; return 1; }
    local resp; resp=$(_codecommit_iam UploadSSHPublicKey "UserName=${user}" "SSHPublicKeyBody=${pub_key}")
    local code; code=$(_git_http_code "$resp")
    local body; body=$(_git_http_body "$resp")
    if [[ "$code" == "200" ]]; then
        _codecommit_xml_tag SSHPublicKeyId "$body"
        return 0
    fi
    if echo "$body" | grep -q 'EntityAlreadyExists\|DuplicateSSHPublicKey'; then
        local existing; existing=$(_codecommit_find_key_id "$pub_key") || true
        if [[ -n "$existing" ]]; then
            echo "$existing"
            return 0
        fi
    fi
    error "CodeCommit SSH key failed (HTTP ${code}): $(echo "$body" | grep -oE '<Message>[^<]+' | sed 's/<Message>//' | head -1)"
    return 1
}

_codecommit_remove_ssh_key() {
    local key_id="$1"
    [[ -z "$key_id" || "$key_id" == "null" ]] && return 0
    local user; user=$(_git_server_get "codecommit_iam_user")
    [[ -z "$user" ]] && return 0
    local resp; resp=$(_codecommit_iam DeleteSSHPublicKey "UserName=${user}" "SSHPublicKeyId=${key_id}")
    local code; code=$(_git_http_code "$resp")
    [[ "$code" == "200" || "$code" == "404" ]] && return 0
    if echo "$(_git_http_body "$resp")" | grep -qi 'NoSuchEntity'; then
        return 0
    fi
    warn "CodeCommit remove SSH key: HTTP ${code}"
    return 1
}

# IAM/CodeCommit accept ssh-rsa (2048+) or PEM, not ed25519. Keep the
# app's ed25519 key for Deployer→localhost; mint a 4096-bit RSA for AWS.
_codecommit_app_pubkey() {
    local app="$1"
    local home="/home/${app}"
    # ~/.ssh is the app user's: made, written and read by that user (app_as
    # in common.sh), here and in the functions below.
    app_mkdir "$app" "${home}/.ssh"
    if [[ ! -f "${home}/.ssh/id_rsa.pub" ]]; then
        sudo -u "$app" ssh-keygen -t rsa -b 4096 -C "${app}@cipi-codecommit" -f "${home}/.ssh/id_rsa" -N "" -q
        app_sh "$app" 'chmod 600 "$1/id_rsa"; chmod 644 "$1/id_rsa.pub"' "${home}/.ssh" < /dev/null
    fi
    app_read "$app" "${home}/.ssh/id_rsa.pub"
}

_codecommit_write_ssh_config() {
    local app="$1" key_id="$2"
    [[ -z "$app" || -z "$key_id" || "$key_id" == "null" ]] && return 0
    local cfg="/home/${app}/.ssh/config"
    app_mkdir "$app" "/home/${app}/.ssh"
    # Drop a previous Cipi CodeCommit block, then write the SSH Key ID as User:
    # the file without the old block, then the new one, written whole by the
    # app user (app_write takes all of its input before it opens the file).
    {
        if [[ -f "$cfg" ]]; then
            app_read "$app" "$cfg" | awk '
                /^# cipi-codecommit-begin$/ {skip=1; next}
                /^# cipi-codecommit-end$/ {skip=0; next}
                !skip {print}
            ' || true
        fi
        cat <<EOF
# cipi-codecommit-begin
Host git-codecommit.*.amazonaws.com
  User ${key_id}
  IdentityFile ~/.ssh/id_rsa
  IdentitiesOnly yes
# cipi-codecommit-end
EOF
    } | app_write "$app" "$cfg" 600
}

# ── DISPATCH ─────────────────────────────────────────────────

_git_add_deploy_key() {
    local provider="$1" repo="$2" title="$3" pub_key="$4"
    case "$provider" in
        github)     _github_add_deploy_key "$repo" "$title" "$pub_key" ;;
        gitlab)     _gitlab_add_deploy_key "$repo" "$title" "$pub_key" ;;
        origin)     _origin_add_ssh_key "$title" "$pub_key" ;;
        bitbucket)  _bitbucket_add_deploy_key "$repo" "$title" "$pub_key" ;;
        azure)      _azure_add_ssh_key "$repo" "$title" "$pub_key" ;;
        codecommit) _codecommit_add_ssh_key "$pub_key" ;;
        *) return 1 ;;
    esac
}

_git_remove_deploy_key() {
    local provider="$1" repo="$2" key_id="$3"
    case "$provider" in
        github)     _github_remove_deploy_key "$repo" "$key_id" ;;
        gitlab)     _gitlab_remove_deploy_key "$repo" "$key_id" ;;
        origin)     _origin_remove_ssh_key "$key_id" ;;
        bitbucket)  _bitbucket_remove_deploy_key "$repo" "$key_id" ;;
        azure)      _azure_remove_ssh_key "$repo" "$key_id" ;;
        codecommit) _codecommit_remove_ssh_key "$key_id" ;;
        *) return 0 ;;
    esac
}

_git_add_webhook() {
    local provider="$1" repo="$2" webhook_url="$3" secret="$4"
    case "$provider" in
        github)    _github_add_webhook "$repo" "$webhook_url" "$secret" ;;
        gitlab)    _gitlab_add_webhook "$repo" "$webhook_url" "$secret" ;;
        bitbucket) _bitbucket_add_webhook "$repo" "$webhook_url" "$secret" ;;
        azure)     _azure_add_webhook "$repo" "$webhook_url" "$secret" ;;
        *) return 1 ;;
    esac
}

_git_remove_webhook() {
    local provider="$1" repo="$2" hook_id="$3"
    case "$provider" in
        github)    _github_remove_webhook "$repo" "$hook_id" ;;
        gitlab)    _gitlab_remove_webhook "$repo" "$hook_id" ;;
        bitbucket) _bitbucket_remove_webhook "$repo" "$hook_id" ;;
        azure)     _azure_remove_webhook "$repo" "$hook_id" ;;
        *) return 0 ;;
    esac
}

_git_find_deploy_key_id() {
    local provider="$1" repo="$2" pub_key="$3"
    case "$provider" in
        github)     _github_find_deploy_key_id "$repo" "$pub_key" ;;
        gitlab)     _gitlab_find_deploy_key_id "$repo" "$pub_key" ;;
        origin)     _origin_find_ssh_key_id "$pub_key" ;;
        bitbucket)  _bitbucket_find_deploy_key_id "$repo" "$pub_key" ;;
        azure)      _azure_find_ssh_key_id "$repo" "$pub_key" ;;
        codecommit) _codecommit_find_key_id "$pub_key" ;;
        *) return 1 ;;
    esac
}

_git_find_webhook_ids() {
    local provider="$1" repo="$2" webhook_url="$3"
    case "$provider" in
        github)    _github_find_webhook_ids "$repo" "$webhook_url" ;;
        gitlab)    _gitlab_find_webhook_ids "$repo" "$webhook_url" ;;
        bitbucket) _bitbucket_find_webhook_ids "$repo" "$webhook_url" ;;
        azure)     _azure_find_webhook_ids "$repo" "$webhook_url" ;;
        *) return 0 ;;
    esac
}

_git_remove_deploy_keys_by_title() {
    local provider="$1" repo="$2" title="$3"
    case "$provider" in
        github)    _github_remove_deploy_keys_by_title "$repo" "$title" ;;
        gitlab)    _gitlab_remove_deploy_keys_by_title "$repo" "$title" ;;
        origin)    _origin_remove_ssh_keys_by_title "$title" ;;
        bitbucket) _bitbucket_remove_deploy_keys_by_title "$repo" "$title" ;;
        azure)     _azure_remove_ssh_keys_by_title "$repo" "$title" ;;
        *) return 0 ;;
    esac
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

    if ! _git_provider_ready "$provider"; then
        info "No ${provider} credentials — skipping auto-setup (manual config needed)"
        info "Set them with: $(_git_token_hint "$provider")"
        return 0
    fi

    GIT_PROVIDER="$provider"
    local webhook_url="https://$(domain_url_host "$domain")/cipi/webhook"
    local repo_id; repo_id=$(_git_parse_repo "$provider" "$repository")
    local label; label=$(_git_provider_label "$provider")

    step "Configuring ${label} integration..."

    if [[ "$provider" == "codecommit" ]]; then
        pub_key=$(_codecommit_app_pubkey "$app") || pub_key=""
    fi
    # The forge's answer is kept (GIT_SETUP_KEY_ERROR, GIT_SETUP_HOOK_ERROR)
    # for the create summary: swallowing it left "add it manually" with no
    # reason, and the panel showed nothing at all.
    GIT_SETUP_KEY_ERROR="" GIT_SETUP_HOOK_ERROR=""
    local out
    if out=$(_git_add_deploy_key "$provider" "$repo_id" "cipi:${app}" "$pub_key" 2>&1); then
        GIT_DEPLOY_KEY_ID="$out"
    else
        GIT_DEPLOY_KEY_ID=""
        GIT_SETUP_KEY_ERROR=$(_git_last_message "$out")
        warn "Could not add the deploy key to ${label}: ${GIT_SETUP_KEY_ERROR:-no answer}"
    fi
    if [[ "$provider" == "codecommit" && -n "$GIT_DEPLOY_KEY_ID" ]]; then
        _codecommit_write_ssh_config "$app" "$GIT_DEPLOY_KEY_ID"
    fi

    if _git_provider_webhooks "$provider" && [[ "$skip_webhook" != "skip_webhook" && -n "$webhook_token" ]]; then
        if out=$(_git_add_webhook "$provider" "$repo_id" "$webhook_url" "$webhook_token" 2>&1); then
            GIT_WEBHOOK_ID="$out"
        else
            GIT_WEBHOOK_ID=""
            GIT_SETUP_HOOK_ERROR=$(_git_last_message "$out")
            warn "Could not add the webhook to ${label}: ${GIT_SETUP_HOOK_ERROR:-no answer}"
        fi
    elif [[ "$skip_webhook" != "skip_webhook" && -n "$webhook_token" ]] && ! _git_provider_webhooks "$provider"; then
        info "${label} has no HTTP deploy webhook — trigger deploys with: cipi deploy ${app}"
    fi

    if [[ "$skip_webhook" == "skip_webhook" ]]; then
        [[ -n "$GIT_DEPLOY_KEY_ID" ]] && success "${label} deploy key configured (webhook skipped)"
    elif [[ -n "$GIT_DEPLOY_KEY_ID" && -n "$GIT_WEBHOOK_ID" ]]; then
        success "${label} deploy key + webhook configured automatically"
    elif [[ -n "$GIT_DEPLOY_KEY_ID" ]]; then
        success "${label} deploy key added"
        warn "No webhook: a push will not deploy until it exists — fix the token, then: cipi git refresh ${app}"
    elif [[ -n "$GIT_WEBHOOK_ID" ]]; then
        success "${label} webhook added (deploy key needs manual setup)"
    fi
}

# The last non-empty line of a captured error, without colours or the
# "[ERROR]" prefix: what the forge said, ready for a summary line.
_git_last_message() {
    printf '%s\n' "$1" | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^\[ERROR\] //' -e 's/^\[WARN\] //' \
        | grep -v '^[[:space:]]*$' | tail -1
}

# ── REPOSITORY ACCESS ────────────────────────────────────────
#
# Can the app actually read its repository with the deploy key? Checked as soon
# as the key is in place (app create, app edit --repository / --branch, cipi git
# check): a clone that fails at the first deploy is the wrong moment to learn
# that the token had expired or the key was never added.

# git ls-remote as the app user, with the identity Deployer uses. Returns 0
# when the branch exists, 2 when the repository answers but has no such branch,
# 1 when it cannot be read at all. The last line git printed is left in
# GIT_ACCESS_ERROR. A key the forge has just accepted can take a moment to
# serve, so a refused read is tried once more.
_git_ls_remote() {
    local app="$1" repository="$2" branch="${3:-main}"
    local home="/home/${app}" out rc attempt
    local ssh_cmd="ssh -i ${home}/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=15"
    GIT_ACCESS_ERROR=""
    for attempt in 1 2; do
        rc=0
        out=$(timeout 60 sudo -u "$app" -H env GIT_SSH_COMMAND="$ssh_cmd" GIT_TERMINAL_PROMPT=0 \
            git ls-remote --exit-code --heads "$repository" "refs/heads/${branch}" 2>&1) || rc=$?
        [[ $rc -eq 0 ]] && return 0
        [[ $rc -eq 2 ]] && return 2
        # The line that says why: GitHub's "ERROR: Repository not found." comes
        # first, before the generic "Please make sure you have the correct
        # access rights" tail; ssh's "Permission denied (publickey)" likewise.
        GIT_ACCESS_ERROR=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | grep -v '^Warning: Permanently added' \
            | grep -m1 -E 'ERROR|Permission denied|Host key|Could not resolve|Connection|denied|not found|No such|timed out|does not exist' \
            || printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | grep -v '^Warning: Permanently added' | head -1)
        [[ $rc -eq 124 ]] && GIT_ACCESS_ERROR="no answer from the git host within 60s"
        [[ $attempt -eq 1 ]] && sleep 3
    done
    return 1
}

# Check, report, and on a terminal offer the fix. Sets GIT_REPO_ACCESS to
# ok | nobranch | denied for the caller's summary. Returns 0 only for ok.
#
# Usage: git_verify_repo_access <app> <repository> <branch> [<domain> <webhook_token> <pub_key> [skip_webhook]]
# With a public key, a refused read on a forge Cipi knows offers to save (or
# replace) that forge's token, runs git_setup_repo again — deploy key and
# webhook — and checks once more. The caller saves GIT_PROVIDER /
# GIT_DEPLOY_KEY_ID / GIT_WEBHOOK_ID afterwards, as after git_setup_repo.
# shellcheck disable=SC2034  # GIT_REPO_ACCESS is read by the app create summary (app.sh)
git_verify_repo_access() {
    local app="$1" repository="$2" branch="${3:-main}"
    local domain="${4:-}" webhook_token="${5:-}" pub_key="${6:-}" skip_webhook="${7:-}"
    GIT_REPO_ACCESS=""
    [[ -z "$repository" ]] && return 0
    local provider label rc
    provider=$(_git_detect_provider "$repository")
    label=$(_git_provider_label "${provider:-git}")
    [[ -z "$provider" ]] && label="the git host"

    step "Repository access..."
    _git_ls_remote "$app" "$repository" "$branch"; rc=$?
    if [[ $rc -eq 0 ]]; then
        success "Repository reachable — branch '${branch}' found"
        GIT_REPO_ACCESS="ok"; return 0
    fi
    if [[ $rc -eq 2 ]]; then
        warn "Repository reachable, but it has no branch '${branch}'"
        info "Pick an existing one: cipi app edit ${app} --branch=<name>"
        GIT_REPO_ACCESS="nobranch"; return 1
    fi

    warn "Cannot read the repository with the deploy key${GIT_ACCESS_ERROR:+: ${GIT_ACCESS_ERROR}}"
    GIT_REPO_ACCESS="denied"

    # The fix, on a terminal: a token for the forge, then the key goes in by itself.
    if [[ -t 0 && -n "$pub_key" && -n "$provider" && "$provider" != "codecommit" ]]; then
        local question
        if _git_provider_ready "$provider"; then
            question="The ${label} token may have expired or not cover this repository. Replace it and retry?"
        else
            question="No ${label} token is saved. Save one now and retry? (Cipi then adds the deploy key for you)"
        fi
        if confirm "$question"; then
            local token
            echo -e -n "${CYAN}${label} token${NC}: "; read -rs token; echo ""
            if [[ -n "$token" ]]; then
                _git_set_named_token "${provider}_token" "$label" "cipi git ${provider}-token <token>" "$token"
                git_setup_repo "$app" "$repository" "$domain" "$webhook_token" "$pub_key" "$skip_webhook"
                step "Repository access..."
                _git_ls_remote "$app" "$repository" "$branch"; rc=$?
                if [[ $rc -eq 0 ]]; then
                    success "Repository reachable — branch '${branch}' found"
                    GIT_REPO_ACCESS="ok"; return 0
                elif [[ $rc -eq 2 ]]; then
                    warn "Repository reachable, but it has no branch '${branch}'"
                    info "Pick an existing one: cipi app edit ${app} --branch=<name>"
                    GIT_REPO_ACCESS="nobranch"; return 1
                fi
                warn "Still cannot read the repository${GIT_ACCESS_ERROR:+: ${GIT_ACCESS_ERROR}}"
            else
                info "No token entered"
            fi
        fi
    fi

    # What to do, for a script or a declined prompt.
    if [[ -n "$provider" && "$provider" != "codecommit" ]]; then
        if _git_provider_ready "$provider"; then
            info "Renew the ${label} token, then re-register the key:"
            info "  $(_git_token_hint "$provider") && cipi git refresh ${app}"
        else
            info "Save a ${label} token and Cipi adds the deploy key for you:"
            info "  $(_git_token_hint "$provider") && cipi git refresh ${app}"
        fi
    elif [[ "$provider" == "codecommit" ]]; then
        if _git_provider_ready "$provider"; then
            info "Check the IAM user and its SSH keys (five at most), then: cipi git refresh ${app}"
        else
            info "Save the IAM credentials and Cipi uploads the key: $(_git_token_hint "$provider") && cipi git refresh ${app}"
        fi
    else
        info "Add the deploy key to the repository (cipi deploy ${app} --key shows it)"
        info "A host on a non-standard port or an unknown host key: cipi deploy ${app} --trust-host=<host[:port]>"
    fi
    info "Check again at any time: cipi git check ${app}"
    return 1
}

# cipi git check [app] — the same check for one app, or for every app with a
# repository. Without an app no token is offered; a token is saved once and
# `cipi git refresh` covers the rest.
_git_check() {
    local target="${1:-}"
    if [[ -n "$target" ]]; then
        app_exists "$target" || { error "App '${target}' not found"; exit 1; }
        local repository branch pub_key="" custom skip=""
        repository=$(app_get "$target" repository)
        [[ -z "$repository" ]] && { info "${target}: no git repository"; return 0; }
        branch=$(app_get "$target" branch)
        custom=$(app_get "$target" custom)
        [[ -f "/home/${target}/.ssh/id_ed25519.pub" ]] && pub_key=$(app_read "$target" "/home/${target}/.ssh/id_ed25519.pub" || true)
        [[ "$custom" == "true" && "$(app_get "$target" runtime)" != "node" ]] && skip="skip_webhook"
        echo -e "\n${BOLD}${target}${NC} ${DIM}${repository} (${branch:-main})${NC}"
        if git_verify_repo_access "$target" "$repository" "${branch:-main}" \
                "$(app_get "$target" domain)" "$(app_get "$target" webhook_token)" "$pub_key" "$skip"; then
            [[ -n "${GIT_PROVIDER:-}" ]] && git_save_app_data "$target" "$GIT_PROVIDER" "${GIT_DEPLOY_KEY_ID:-}" "${GIT_WEBHOOK_ID:-}"
            return 0
        fi
        [[ -n "${GIT_PROVIDER:-}" ]] && git_save_app_data "$target" "$GIT_PROVIDER" "${GIT_DEPLOY_KEY_ID:-}" "${GIT_WEBHOOK_ID:-}"
        exit 1
    fi

    [[ -f "${CIPI_CONFIG}/apps.json" ]] || { info "No apps"; return 0; }
    local apps app ok=0 fail=0 none=0
    apps=$(vault_read apps.json | jq -r 'keys[]')
    [[ -z "$apps" ]] && { info "No apps"; return 0; }
    echo -e "\n${BOLD}Repository access${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    while IFS= read -r app; do
        [[ -n "$app" ]] || continue
        local repository branch
        repository=$(app_get "$app" repository)
        if [[ -z "$repository" ]]; then
            none=$((none + 1)); continue
        fi
        branch=$(app_get "$app" branch)
        echo -e "\n${BOLD}${app}${NC} ${DIM}${repository} (${branch:-main})${NC}"
        if git_verify_repo_access "$app" "$repository" "${branch:-main}"; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi
    done <<< "$apps"
    echo ""
    [[ $none -gt 0 ]] && info "${none} app(s) without a repository skipped"
    if [[ $fail -gt 0 ]]; then
        error "${fail} app(s) cannot read their repository, ${ok} can"
        exit 1
    fi
    success "Every app with a repository can read it (${ok})"
}

# Remove deploy key + webhook from git provider
git_cleanup_repo() {
    local app="$1" repository="$2"
    local provider; provider=$(app_get "$app" git_provider 2>/dev/null || true)
    local key_id; key_id=$(app_get "$app" git_deploy_key_id 2>/dev/null || true)
    local hook_id; hook_id=$(app_get "$app" git_webhook_id 2>/dev/null || true)

    [[ -z "$provider" ]] && return 0
    [[ -z "$key_id" && -z "$hook_id" ]] && return 0

    if ! _git_provider_ready "$provider"; then
        warn "No ${provider} credentials — cannot remove deploy key/webhook from repo automatically"
        return 0
    fi

    local label; label=$(_git_provider_label "$provider")
    step "Removing ${label} integration..."

    local repo_id; repo_id=$(_git_parse_repo "$provider" "$repository")
    _git_remove_deploy_key "$provider" "$repo_id" "$key_id" 2>/dev/null || true
    _git_remove_webhook "$provider" "$repo_id" "$hook_id" 2>/dev/null || true

    success "${label} deploy key + webhook removed"
}

# Save git integration data into apps.json (uses jq numeric for IDs)
git_save_app_data() {
    local app="$1" provider="$2" key_id="$3" hook_id="$4"

    if [[ -n "$provider" ]]; then
        app_set "$app" git_provider "$provider"
    fi
    _git_app_set_id "$app" git_deploy_key_id "$key_id"
    _git_app_set_id "$app" git_webhook_id "$hook_id"
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

    local repository domain provider hook_id wt webhook_url
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

    if ! _git_provider_ready "$provider"; then
        error "No ${provider} credentials — set with: $(_git_token_hint "$provider")"
        return 1
    fi
    if ! _git_provider_webhooks "$provider"; then
        error "$(_git_provider_label "$provider") has no HTTP deploy webhook"
        return 1
    fi

    if [[ "$rotate" == "true" ]]; then
        step "Rotating webhook secret..."
        wt=$(generate_token)
        app_set "$app" webhook_token "$wt"
        if [[ -f "/home/${app}/shared/.env" ]]; then
            _git_env_webhook_token "$app" "$wt"
            success "CIPI_WEBHOOK_TOKEN updated in shared/.env"
        fi
    fi

    webhook_url="https://$(domain_url_host "$domain")/cipi/webhook"
    step "Recreating ${provider} webhook..."

    local repo_id; repo_id=$(_git_parse_repo "$provider" "$repository")
    local new_hook_id=""
    [[ -n "$hook_id" ]] && _git_remove_webhook "$provider" "$repo_id" "$hook_id" 2>/dev/null || true
    new_hook_id=$(_git_add_webhook "$provider" "$repo_id" "$webhook_url" "$wt" 2>&1) || {
        error "Could not recreate ${provider} webhook: ${new_hook_id}"
        return 1
    }

    if [[ -z "$new_hook_id" || "$new_hook_id" == "null" ]]; then
        error "Webhook recreate failed — empty hook id"
        return 1
    fi

    app_set "$app" git_provider "$provider"
    _git_app_set_id "$app" git_webhook_id "$new_hook_id"

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
    local provider hook_id key_id wt

    provider=$(app_get "$app" git_provider 2>/dev/null || true)
    hook_id=$(app_get "$app" git_webhook_id 2>/dev/null || true)
    key_id=$(app_get "$app" git_deploy_key_id 2>/dev/null || true)
    wt=$(app_get "$app" webhook_token 2>/dev/null || true)

    [[ -z "$provider" || -z "$hook_id" || -z "$wt" || -z "$repository" ]] && return 0

    if ! _git_provider_ready "$provider"; then
        warn "No ${provider} credentials — update webhook URL manually: https://$(domain_url_host "$domain")/cipi/webhook"
        return 0
    fi
    if ! _git_provider_webhooks "$provider"; then
        return 0
    fi

    local webhook_url="https://$(domain_url_host "$domain")/cipi/webhook"
    step "Updating ${provider} webhook..."

    local repo_id; repo_id=$(_git_parse_repo "$provider" "$repository")
    local new_hook_id=""
    _git_remove_webhook "$provider" "$repo_id" "$hook_id" 2>/dev/null || true
    new_hook_id=$(_git_add_webhook "$provider" "$repo_id" "$webhook_url" "$wt" 2>&1) || {
        warn "Could not update ${provider} webhook — set manually: ${webhook_url}"
        return 0
    }

    if [[ -n "$new_hook_id" ]]; then
        _git_app_set_id "$app" git_webhook_id "$new_hook_id"
        success "${provider} webhook → ${domain}"
    fi
}

# Generate a new ed25519 deploy key for an app and swap it in authorized_keys
# (Deployer SSHs to localhost with this key). Prints the new public key.
# CIPI_WEBHOOK_TOKEN in the app's shared/.env, set as the app user.
_git_env_webhook_token() {   # <app> <token>
    local app="$1" wt="$2" env="/home/${1}/shared/.env" cur=""
    cur=$(app_read "$app" "$env") || cur=""
    if grep -q '^CIPI_WEBHOOK_TOKEN=' <<< "$cur"; then
        app_sed "$app" "$env" "s|^CIPI_WEBHOOK_TOKEN=.*|CIPI_WEBHOOK_TOKEN=${wt}|"
    else
        echo "CIPI_WEBHOOK_TOKEN=${wt}" | app_append "$app" "$env"
    fi
}

_git_rotate_local_key() {
    local app="$1"
    local home="/home/${app}"
    local old_pub="" blob=""
    # ~/.ssh is the app user's: the key pair is made and authorized_keys is
    # edited by that user (app_as in common.sh). Root ran mkdir, chmod and
    # chown on ~/.ssh, by name — with ~/.ssh a symlink, on the directory it
    # pointed at, which became the app's — and then touch, mv and chown on
    # the files inside.
    [[ -f "${home}/.ssh/id_ed25519.pub" ]] && old_pub=$(app_read "$app" "${home}/.ssh/id_ed25519.pub" || true)
    app_mkdir "$app" "${home}/.ssh" 700
    app_rm "$app" "${home}/.ssh/id_ed25519" "${home}/.ssh/id_ed25519.pub"
    sudo -u "$app" ssh-keygen -t ed25519 -C "${app}@cipi" -f "${home}/.ssh/id_ed25519" -N "" -q
    app_sh "$app" 'chmod 600 "$1/id_ed25519"; chmod 644 "$1/id_ed25519.pub"' "${home}/.ssh" < /dev/null
    local new_pub; new_pub=$(app_read "$app" "${home}/.ssh/id_ed25519.pub")
    local ak="${home}/.ssh/authorized_keys"
    [[ -n "$old_pub" ]] && blob=$(_git_key_blob "$old_pub")
    # The old key's line out, the new one in: a new file renamed over the old
    # one when there is a line to drop, an append when there is not.
    printf '%s\n' "$new_pub" | _app_file_op "$app" "$ak" '
        ak="$1"; blob="$2"; umask 077
        touch "$ak" || exit 1
        if [[ -n "$blob" ]]; then
            t=$(mktemp "${ak}.XXXXXX") || exit 1
            grep -vF -- "$blob" "$ak" > "$t" || true
            cat >> "$t" && mv -f "$t" "$ak" || { rm -f "$t"; exit 1; }
        else
            cat >> "$ak" || exit 1
        fi
        chmod 600 "$ak"' "$blob"
    app_as "$app" chmod 700 "${home}/.ssh" < /dev/null
    printf '%s\n' "$new_pub"
}

# Re-register this app's local deploy key and webhook on the git provider.
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
    if ! _git_provider_ready "$provider"; then
        warn "${app}: no ${provider} credentials — skipped ($(_git_token_hint "$provider"))"
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
        pub_key=$(app_read "$app" "$pub_path")
    fi

    local webhook_url="https://$(domain_url_host "$domain")/cipi/webhook"
    local skip_webhook="true"
    if [[ ( "$custom" != "true" || "$(app_get "$app" runtime 2>/dev/null)" == "node" ) && -n "$wt" ]]; then
        skip_webhook="false"
    fi

    if [[ "$skip_webhook" == "false" && "$rotate_secret" == "true" ]]; then
        step "Rotating webhook secret..."
        wt=$(generate_token)
        app_set "$app" webhook_token "$wt"
        if [[ -f "${home}/shared/.env" ]]; then
            _git_env_webhook_token "$app" "$wt"
        fi
        success "Webhook secret rotated"
    fi

    local new_key_id="" new_hook_id=""
    local title="cipi:${app}"
    local repo_id; repo_id=$(_git_parse_repo "$provider" "$repository")
    local label; label=$(_git_provider_label "$provider")

    step "Refreshing ${label} deploy key..."
    if [[ "$provider" == "codecommit" ]]; then
        if [[ "$rotate_keys" == "true" ]]; then
            app_rm "$app" "${home}/.ssh/id_rsa" "${home}/.ssh/id_rsa.pub" || true
        fi
        pub_key=$(_codecommit_app_pubkey "$app") || {
            error "${app}: could not generate CodeCommit RSA key"
            return 1
        }
    fi
    [[ -n "$key_id" ]] && _git_remove_deploy_key "$provider" "$repo_id" "$key_id" 2>/dev/null || true
    _git_remove_deploy_keys_by_title "$provider" "$repo_id" "$title" || true
    new_key_id=$(_git_add_deploy_key "$provider" "$repo_id" "$title" "$pub_key") || new_key_id=""
    if [[ -z "$new_key_id" || "$new_key_id" == "null" ]]; then
        new_key_id=$(_git_find_deploy_key_id "$provider" "$repo_id" "$pub_key") || true
    fi
    # Same pubkey already used as a deploy key on another repo / account slot.
    # Only when the token can see the repository: a 404/401/403 is the token
    # or the URL, and a new key would not change that — it would only drop
    # the key the old repository still accepts.
    if [[ -z "$new_key_id" || "$new_key_id" == "null" ]] && [[ "$did_rotate_keys" != "true" ]]; then
        local visible=0
        _git_repo_visible "$provider" "$repo_id" || visible=$?
        if [[ $visible -eq 1 ]]; then
            error "${app}: could not add ${label} deploy key — '${repo_id}' is not reachable with the saved token (HTTP ${GIT_REPO_VISIBLE_CODE})"
            info "Fix the token or the repository URL, then run again: cipi git refresh ${app}"
            return 1
        fi
        warn "${app}: deploy key already used on another repo — generating a new one"
        pub_key=$(_git_rotate_local_key "$app") || {
            error "${app}: could not rotate SSH key"
            return 1
        }
        did_rotate_keys="true"
        new_key_id=$(_git_add_deploy_key "$provider" "$repo_id" "$title" "$pub_key") || new_key_id=""
    fi
    if [[ -z "$new_key_id" || "$new_key_id" == "null" ]]; then
        error "${app}: could not add ${label} deploy key"
        info "Once the token is right, run again: cipi git refresh ${app}"
        return 1
    fi
    if [[ "$provider" == "codecommit" ]]; then
        _codecommit_write_ssh_config "$app" "$new_key_id"
    fi

    if [[ "$skip_webhook" != "true" ]] && _git_provider_webhooks "$provider"; then
        step "Refreshing ${label} webhook..."
        [[ -n "$hook_id" ]] && _git_remove_webhook "$provider" "$repo_id" "$hook_id" 2>/dev/null || true
        local extra; extra=$(_git_find_webhook_ids "$provider" "$repo_id" "$webhook_url") || true
        local hid
        for hid in $extra; do
            _git_remove_webhook "$provider" "$repo_id" "$hid" 2>/dev/null || true
        done
        new_hook_id=$(_git_add_webhook "$provider" "$repo_id" "$webhook_url" "$wt") || new_hook_id=""
        if [[ -z "$new_hook_id" || "$new_hook_id" == "null" ]]; then
            error "${app}: could not add ${label} webhook"
            git_save_app_data "$app" "$provider" "$new_key_id" ""
            return 1
        fi
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
        warn "This will generate a NEW SSH deploy key for every git app and re-register it on the git provider."
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

_git_notify_creds() {
    local label="$1" action="$2"
    cipi_notify \
        "Cipi ${label} ${action} on $(hostname)" \
        "Git provider credentials were ${action}.\n\nServer: $(hostname)\nProvider: ${label}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        git_configure
}

_git_set_named_token() {
    local key="$1" label="$2" usage="$3" token="${4:-}"
    [[ -z "$token" ]] && { error "Usage: ${usage}"; exit 1; }
    _git_server_set "$key" "$token"
    log_action "GIT: ${label} token configured"
    _git_notify_creds "$label" "configured"
    success "${label} token saved"
}

_git_set_github_token() {
    _git_set_named_token "github_token" "GitHub" "cipi git github-token <token>" "$@"
}

_git_set_gitlab_token() {
    _git_set_named_token "gitlab_token" "GitLab" "cipi git gitlab-token <token>" "$@"
}

_git_set_origin_token() {
    _git_set_named_token "origin_token" "Origin" "cipi git origin-token <token>" "$@"
}

_git_set_bitbucket_token() {
    _git_set_named_token "bitbucket_token" "Bitbucket" "cipi git bitbucket-token <token>" "$@"
}

_git_set_azure_token() {
    _git_set_named_token "azure_token" "Azure DevOps" "cipi git azure-token <PAT>" "$@"
}

_git_set_codecommit_token() {
    local access_key="${1:-}" secret_key="${2:-}" iam_user="${3:-}"
    [[ -z "$access_key" || -z "$secret_key" || -z "$iam_user" ]] && {
        error "Usage: cipi git codecommit-token <access-key> <secret-key> <iam-user>"
        exit 1
    }
    _git_server_set "codecommit_access_key" "$access_key"
    _git_server_set "codecommit_secret_key" "$secret_key"
    _git_server_set "codecommit_iam_user" "$iam_user"
    log_action "GIT: CodeCommit credentials configured"
    _git_notify_creds "CodeCommit" "configured"
    success "CodeCommit credentials saved (IAM user ${iam_user})"
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

_git_remove_named_token() {
    local label="$1"
    shift
    local k
    for k in "$@"; do
        _git_server_remove "$k"
    done
    log_action "GIT: ${label} token removed"
    _git_notify_creds "$label" "removed"
    success "${label} credentials removed"
}

_git_remove_github_token() {
    _git_remove_named_token "GitHub" "github_token"
}

_git_remove_gitlab_token() {
    _git_remove_named_token "GitLab" "gitlab_token" "gitlab_url"
}

_git_remove_origin_token() {
    _git_remove_named_token "Origin" "origin_token"
}

_git_remove_bitbucket_token() {
    _git_remove_named_token "Bitbucket" "bitbucket_token"
}

_git_remove_azure_token() {
    _git_remove_named_token "Azure DevOps" "azure_token"
}

_git_remove_codecommit_token() {
    _git_remove_named_token "CodeCommit" "codecommit_access_key" "codecommit_secret_key" "codecommit_iam_user"
}

_git_status_line() {
    local label="$1" token="$2" extra="${3:-}"
    if [[ -n "$token" ]]; then
        local masked="${token:0:4}...${token: -4}"
        if [[ -n "$extra" ]]; then
            printf "  %-16s ${GREEN}● connected${NC} (%s) → %s\n" "$label" "$masked" "$extra"
        else
            printf "  %-16s ${GREEN}● connected${NC} (%s)\n" "$label" "$masked"
        fi
    else
        printf "  %-16s ${DIM}○ not configured${NC}\n" "$label"
    fi
}

_git_status() {
    echo -e "\n${BOLD}Git Provider Integration${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    _git_status_line "GitHub" "$(_git_server_get github_token)"
    local gl_url; gl_url=$(_git_server_get "gitlab_url")
    [[ -z "$gl_url" ]] && gl_url="https://gitlab.com"
    local gl_token; gl_token=$(_git_server_get "gitlab_token")
    if [[ -n "$gl_token" ]]; then
        _git_status_line "GitLab" "$gl_token" "$gl_url"
    else
        _git_status_line "GitLab" ""
    fi
    _git_status_line "Origin" "$(_git_server_get origin_token)"
    _git_status_line "Bitbucket" "$(_git_server_get bitbucket_token)"
    _git_status_line "Azure DevOps" "$(_git_server_get azure_token)"
    local cc_ak; cc_ak=$(_git_server_get "codecommit_access_key")
    local cc_user; cc_user=$(_git_server_get "codecommit_iam_user")
    if [[ -n "$cc_ak" ]]; then
        _git_status_line "CodeCommit" "$cc_ak" "${cc_user:-iam-user}"
    else
        _git_status_line "CodeCommit" ""
    fi

    # Show apps with git integration
    if [[ -f "${CIPI_CONFIG}/apps.json" ]]; then
        local apps_with_git; apps_with_git=$(vault_read apps.json | jq -r 'to_entries[] | select(.value.git_provider != null) | "\(.key)\t\(.value.git_provider)\t\(.value.git_deploy_key_id // "-")\t\(.value.git_webhook_id // "-")"' 2>/dev/null)
        if [[ -n "$apps_with_git" ]]; then
            echo ""
            tbl_start
            tbl_head "APP" "PROVIDER" "DEPLOY KEY" "WEBHOOK"
            tbl_rule
            local a p dk wh
            while IFS=$'\t' read -r a p dk wh; do
                tbl_row "$a" "$p" "$dk" "$wh"
            done <<< "$apps_with_git"
            tbl_print
        fi
    fi

    echo ""
    echo -e "  ${BOLD}Setup:${NC}"
    echo "    cipi git github-token <token>              Save GitHub PAT"
    echo "    cipi git gitlab-token <token>              Save GitLab PAT"
    echo "    cipi git gitlab-url <url>                  Set self-hosted GitLab URL"
    echo "    cipi git origin-token <token>              Save Cursor Origin API key"
    echo "    cipi git bitbucket-token <token>           Save Bitbucket API token"
    echo "    cipi git azure-token <PAT>                 Save Azure DevOps PAT"
    echo "    cipi git codecommit-token <ak> <sk> <user> AWS access key + IAM user"
    echo "    cipi git remove-github                     Remove GitHub token"
    echo "    cipi git remove-gitlab                     Remove GitLab token + URL"
    echo "    cipi git remove-origin                     Remove Origin token"
    echo "    cipi git remove-bitbucket                  Remove Bitbucket token"
    echo "    cipi git remove-azure                      Remove Azure DevOps PAT"
    echo "    cipi git remove-codecommit                 Remove CodeCommit credentials"
    echo "    cipi git refresh [app]                     Re-sync deploy keys + webhooks"
    echo "                                               [--rotate-keys] [--rotate-secret]"
    echo "    cipi git check [app]                       Can the deploy key read the repository?"
    echo ""
}

git_command() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        github-token)      _git_set_github_token "$@" ;;
        gitlab-token)      _git_set_gitlab_token "$@" ;;
        gitlab-url)        _git_set_gitlab_url "$@" ;;
        origin-token)      _git_set_origin_token "$@" ;;
        bitbucket-token)   _git_set_bitbucket_token "$@" ;;
        azure-token)       _git_set_azure_token "$@" ;;
        codecommit-token)  _git_set_codecommit_token "$@" ;;
        remove-github)     _git_remove_github_token ;;
        remove-gitlab)     _git_remove_gitlab_token ;;
        remove-origin)     _git_remove_origin_token ;;
        remove-bitbucket)  _git_remove_bitbucket_token ;;
        remove-azure)      _git_remove_azure_token ;;
        remove-codecommit) _git_remove_codecommit_token ;;
        refresh)           _git_refresh "$@" ;;
        check)             _git_check "$@" ;;
        status|"")         _git_status ;;
        *) error "Unknown: $sub"
           echo "Use: github-token gitlab-token gitlab-url origin-token bitbucket-token azure-token codecommit-token"
           echo "     remove-github remove-gitlab remove-origin remove-bitbucket remove-azure remove-codecommit"
           echo "     refresh check status"
           exit 1 ;;
    esac
}
