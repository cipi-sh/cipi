#!/bin/bash
#############################################
# Cipi — Per-app redirects and prefix proxies (nginx)
#
#   cipi redirect set|enable|disable|unset <app>    whole-app redirect
#   cipi redirect add|remove <app> <from> [<to>]    path redirects
#   cipi proxy add|remove <app> <prefix> [<url>]    reverse proxy on a prefix
#
# State lives in apps.json (.redirect, .redirects[], .proxies[]) and
# _create_nginx_vhost (lib/app.sh) renders it, so rules survive every vhost
# regeneration: alias/www/basicauth changes, PHP switch, sync import.
#
# Input is validated here and only here. Paths and URLs are restricted to a
# charset with no quotes, '$', ';', braces or whitespace, so a rule can never
# inject nginx directives. Every change is applied with `nginx -t`; if nginx
# refuses it, apps.json and the vhost are put back as they were.
#############################################

declare -f _create_nginx_vhost >/dev/null 2>&1 || source "${CIPI_LIB}/app.sh"

# ── validation ────────────────────────────────────────────────

# Regexes live in variables: unquoted '&', '?' and '#' inside [[ =~ ]] are
# parsed by the shell, and a backslash in a bracket expression is literal.
_ROUTES_RE_PATH='^/[A-Za-z0-9._~%/+@:,=-]*$'
_ROUTES_RE_PATH_QUERY='^/[A-Za-z0-9._~%/+@:,=-]*([?][A-Za-z0-9._~%/+@:,=&-]*)?$'
_ROUTES_RE_URL='^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~%/+@:,=&?#!-]*)?$'
_ROUTES_RE_UPSTREAM='^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?(/[A-Za-z0-9._~%/+-]*)?$'

# /path — letters, digits and . _ ~ % / + @ : , = -
_routes_valid_path() {
    local p="$1"
    [[ "$p" =~ $_ROUTES_RE_PATH ]] || return 1
    [[ "$p" == *//* || "$p" == *..* ]] && return 1
    return 0
}

# http(s)://host[:port][/path][?query][#fragment] — hostname or IPv4 only.
_routes_valid_url() {
    [[ "$1" =~ $_ROUTES_RE_URL ]] || return 1
    local port; port=$(_routes_url_port "$1")
    (( port >= 1 && port <= 65535 ))
}

# Upstream for proxy_pass: no query, no fragment.
_routes_valid_upstream() {
    [[ "$1" =~ $_ROUTES_RE_UPSTREAM ]] || return 1
    local port; port=$(_routes_url_port "$1")
    (( port >= 1 && port <= 65535 ))
}

_routes_url_host() {
    local rest="${1#*://}"
    rest="${rest%%/*}"; rest="${rest%%\?*}"; rest="${rest%%#*}"
    printf '%s' "${rest%%:*}" | tr '[:upper:]' '[:lower:]'
}

_routes_url_port() {
    local rest="${1#*://}"
    rest="${rest%%/*}"; rest="${rest%%\?*}"; rest="${rest%%#*}"
    if [[ "$rest" == *:* ]]; then
        printf '%s' "$((10#${rest##*:}))"
    elif [[ "$1" == https://* ]]; then
        printf '443'
    else
        printf '80'
    fi
}

_routes_url_path() {
    local rest="${1#*://}"
    [[ "$rest" == */* ]] && printf '/%s' "${rest#*/}"
    return 0
}

# Echoes 301|302|307|308 from --code=N or --301/--302/--307/--308 (default 301).
_routes_parse_code() {
    local code="" c flag
    for c in 301 302 307 308; do
        flag="ARG_${c}"
        if [[ -n "${!flag:-}" ]]; then
            [[ -n "$code" && "$code" != "$c" ]] && { error "Pick one redirect code, not --${code} and --${c}"; return 1; }
            code="$c"
        fi
    done
    if [[ -n "${ARG_code:-}" ]]; then
        [[ -n "$code" && "$code" != "${ARG_code}" ]] && { error "Conflicting --code=${ARG_code} and --${code}"; return 1; }
        code="${ARG_code}"
    fi
    code="${code:-301}"
    [[ "$code" =~ ^(301|302|307|308)$ ]] || { error "Redirect code must be 301, 302, 307 or 308"; return 1; }
    printf '%s' "$code"
}

# All server names of an app, one per line, lowercase.
_routes_app_names() {
    vault_read apps.json | jq -r --arg a "$1" '.[$a] | [.domain] + (.aliases // []) | .[]' 2>/dev/null \
        | tr '[:upper:]' '[:lower:]'
}

_routes_host_is_app() {
    local app="$1" host="$2" n
    while read -r n; do
        [[ -z "$n" ]] && continue
        [[ "$n" == "$host" ]] && return 0
        # *.example.com covers a.example.com
        [[ "$n" == \*.* && "$host" == *".${n#\*.}" ]] && return 0
    done < <(_routes_app_names "$app")
    return 1
}

# nginx location keys a rule occupies: "=<path>" or "^~<path>".
_routes_rule_keys() {
    local kind="$1" path="$2"
    if [[ "$kind" == proxy ]]; then
        printf '=%s\n^~%s\n' "${path%/}" "$path"
    elif [[ "$path" == */ ]]; then
        printf '=%s\n^~%s\n' "${path%/}" "$path"
    else
        printf '=%s\n' "$path"
    fi
}

# nginx matches locations against the decoded URI, so an encoded source path
# (/a%20b) would never match — ask for the decoded one instead.
_routes_valid_source_path() {
    local p="$1"
    if [[ "$p" == *%* ]]; then
        error "Write '${p}' decoded (nginx matches the decoded path), without %-escapes"
        return 1
    fi
    _routes_valid_path "$p" || { error "Invalid path '${p}'"; return 1; }
}

# Refuse paths the vhost already owns or that would break Cipi itself, and
# paths another rule already occupies. $3 = kind (redirect|proxy); a rule of
# the same kind on the same path is an update, not a collision.
_routes_check_path() {
    local app="$1" path="$2" kind="$3"
    if [[ "$path" == "/" ]]; then
        if [[ "$kind" == proxy ]]; then
            error "A proxy on / would replace the whole app — use a prefix such as /api/"
        else
            error "A redirect of / is the whole app — use: cipi redirect set ${app} --to=<url>"
        fi
        return 1
    fi
    case "$path" in
        /.well-known/acme-challenge*|/.well-known/)
            error "${path} is reserved for Let's Encrypt (ACME challenge)"; return 1 ;;
        /favicon.ico|/robots.txt|/index.php|/index.php/*|/index.html)
            error "${path} is already handled by the app vhost"; return 1 ;;
        /cipi/|/cipi/webhook|/cipi/webhook/*)
            error "${path} would capture the Git deploy webhook (/cipi/webhook)"; return 1 ;;
    esac
    if [[ -n "$(app_get "$app" reverb)" ]]; then
        case "$path" in
            /app|/apps|/app/*|/apps/*)
                error "${path} overlaps Reverb WebSockets (/app, /apps) on this app"; return 1 ;;
        esac
    fi

    local new_key existing
    existing=$(vault_read apps.json | jq -r --arg a "$app" --arg k "$kind" --arg id "$path" '
        ((.[$a].redirects // []) | map(select(($k == "redirect" and .from == $id) | not)) | .[] | "redirect\t\(.from)"),
        ((.[$a].proxies   // []) | map(select(($k == "proxy"    and .prefix == $id) | not)) | .[] | "proxy\t\(.prefix)")
    ' 2>/dev/null)
    [[ -z "$existing" ]] && return 0
    local ekind epath ekey
    while IFS= read -r new_key; do
        while IFS=$'\t' read -r ekind epath; do
            [[ -z "$epath" ]] && continue
            while IFS= read -r ekey; do
                if [[ "$ekey" == "$new_key" ]]; then
                    error "${path} collides with the ${ekind} rule on ${epath}"
                    return 1
                fi
            done < <(_routes_rule_keys "$ekind" "$epath")
        done <<< "$existing"
    done < <(_routes_rule_keys "$kind" "$path")
    return 0
}

# ── apply (with revert) ───────────────────────────────────────

_routes_app_json() { vault_read apps.json | jq -c --arg a "$1" '.[$a]'; }

# Regenerate the vhost and reload. On nginx -t failure restore $2 (the app's
# JSON before the change) and regenerate again, so a bad rule never leaves
# nginx broken or apps.json out of step with the running config.
_routes_apply() {
    local app="$1" before="$2"
    _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)"
    if _nginx_reapply_ssl "$app"; then
        [[ "$(app_get "$app" suspended)" == "true" ]] && \
            warn "'${app}' is suspended — the rule is saved and takes effect on: cipi app unsuspend ${app}"
        return 0
    fi
    error "nginx refused the new configuration — reverting"
    app_save "$app" "$before" || true
    _create_nginx_vhost "$app" "$(app_get "$app" domain)" "$(app_get "$app" php)"
    _nginx_reapply_ssl "$app" >/dev/null 2>&1 || true
    return 1
}

# nginx must be valid before we touch it, or a revert cannot tell our change
# from a problem that was already there.
_routes_preflight() {
    if ! nginx -t >/dev/null 2>&1; then
        error "nginx configuration is already invalid — fix it first (nginx -t)"
        return 1
    fi
}

_routes_notify() {
    local trigger="$1" app="$2" what="$3"
    log_action "${what}"
    cipi_notify \
        "Cipi ${what%%:*}: ${app} on $(hostname)" \
        "${what}\n\nServer: $(hostname)\nApp: ${app}\nDomain: $(app_get "$app" domain)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        "$trigger"
}

_routes_require_app() {
    local app="$1" usage="$2"
    [[ -z "$app" ]] && { error "Usage: ${usage}"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
}

# ══ cipi redirect ═════════════════════════════════════════════

redirect_command() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        set)            redirect_set "$@" ;;
        enable)         redirect_toggle true "$@" ;;
        disable)        redirect_toggle false "$@" ;;
        unset)          redirect_unset "$@" ;;
        add)            redirect_add "$@" ;;
        remove|rm)      redirect_remove "$@" ;;
        list|status|ls) routes_list redirect "$@" ;;
        *) error "Unknown: ${sub}"; echo "Use: set enable disable unset add remove list"; exit 1 ;;
    esac
}

# cipi redirect set <app> --to=<url> [--301|--302|--307|--308] [--no-path]
redirect_set() {
    local app="${1:-}"; shift || true
    _routes_require_app "$app" "cipi redirect set <app> --to=https://example.com [--301|--302|--307|--308] [--no-path]"
    parse_args "$@"

    local to="${ARG_to:-}" code keep=true
    [[ -z "$to" ]] && { error "Missing --to=<url>"; exit 1; }
    _routes_valid_url "$to" || { error "Invalid URL '${to}' — expected http(s)://host[/path]"; exit 1; }
    code=$(_routes_parse_code) || exit 1
    [[ "${ARG_no_path:-}" == "true" ]] && keep=false

    if $keep && [[ "$to" == *[?#]* ]]; then
        error "A target with ?query or #fragment cannot keep the request path — add --no-path"; exit 1
    fi
    if _routes_host_is_app "$app" "$(_routes_url_host "$to")"; then
        error "'$(_routes_url_host "$to")' is served by '${app}' itself — the redirect would loop"; exit 1
    fi
    _routes_preflight || exit 1

    local before; before=$(_routes_app_json "$app")
    app_set_json "$app" redirect "$(jq -nc --arg t "$to" --argjson c "$code" --argjson k "$keep" \
        '{enabled: true, to: $t, code: $c, keep_path: $k}')"
    _routes_apply "$app" "$before" || exit 1

    _routes_notify redirect_change "$app" "REDIRECT SET: ${app} → ${to} (${code}$($keep && echo ', path kept'))"
    success "All of '${app}' now redirects ${code} → ${to}$($keep && echo '<path>')"
    local n; n=$(vault_read apps.json | jq --arg a "$app" '(.[$a].redirects // []) + (.[$a].proxies // []) | length')
    if [[ "$n" -gt 0 ]]; then
        info "${n} path rule(s) still apply before the redirect (cipi redirect list ${app})"
    fi
}

# cipi redirect enable|disable <app> — keep the saved target, toggle it.
redirect_toggle() {
    local state="$1" app="${2:-}"
    local verb; [[ "$state" == true ]] && verb=enable || verb=disable
    _routes_require_app "$app" "cipi redirect ${verb} <app>"

    local cur; cur=$(vault_read apps.json | jq -c --arg a "$app" '.[$a].redirect // empty')
    if [[ -z "$cur" || "$(jq -r '.to // ""' <<< "$cur")" == "" ]]; then
        error "No app redirect saved for '${app}' — first: cipi redirect set ${app} --to=<url>"; exit 1
    fi
    if [[ "$(jq -r '.enabled' <<< "$cur")" == "$state" ]]; then
        info "App redirect for '${app}' is already ${verb}d"; return 0
    fi
    _routes_preflight || exit 1

    local before; before=$(_routes_app_json "$app")
    app_set_json "$app" redirect "$(jq -c --argjson s "$state" '.enabled = $s' <<< "$cur")"
    _routes_apply "$app" "$before" || exit 1

    local to; to=$(jq -r '.to' <<< "$cur")
    _routes_notify redirect_change "$app" "REDIRECT $(tr '[:lower:]' '[:upper:]' <<< "$verb")D: ${app} → ${to}"
    if [[ "$state" == true ]]; then
        success "App redirect enabled: ${app} → ${to} ($(jq -r '.code' <<< "$cur"))"
    else
        success "App redirect disabled for '${app}' — the app is served again (target kept)"
    fi
}

redirect_unset() {
    local app="${1:-}"
    _routes_require_app "$app" "cipi redirect unset <app>"
    if [[ -z "$(vault_read apps.json | jq -c --arg a "$app" '.[$a].redirect // empty')" ]]; then
        info "No app redirect saved for '${app}'"; return 0
    fi
    _routes_preflight || exit 1

    local before; before=$(_routes_app_json "$app")
    app_unset "$app" redirect
    _routes_apply "$app" "$before" || exit 1
    _routes_notify redirect_change "$app" "REDIRECT UNSET: ${app}"
    success "App redirect removed for '${app}'"
}

# cipi redirect add <app> <from> <to> [--301|--302|--307|--308] [--no-path]
redirect_add() {
    local app="${1:-}" from="${2:-}" to="${3:-}"
    local usage="cipi redirect add <app> <from> <to> [--301|--302|--307|--308] [--no-path]"
    _routes_require_app "$app" "$usage"
    [[ -z "$from" || -z "$to" || "$from" == --* || "$to" == --* ]] && { error "Usage: ${usage}"; exit 1; }
    shift 3
    parse_args "$@"

    [[ "$from" != /* ]] && from="/${from}"
    _routes_valid_source_path "$from" || exit 1
    if [[ "$to" == /* ]]; then
        if ! [[ "$to" =~ $_ROUTES_RE_PATH_QUERY ]] || ! _routes_valid_path "${to%%\?*}"; then
            error "Invalid target path '${to}'"; exit 1
        fi
    else
        _routes_valid_url "$to" || { error "Invalid target '${to}' — a /path or an http(s):// URL"; exit 1; }
    fi

    local code keep=true prefix=false
    code=$(_routes_parse_code) || exit 1
    [[ "${ARG_no_path:-}" == "true" ]] && keep=false
    [[ "$from" == */ ]] && prefix=true
    _routes_check_path "$app" "$from" redirect || exit 1

    # Same-host target: a relative path, or a URL on one of the app's names.
    local to_path="" same_host=false
    if [[ "$to" == /* ]]; then
        same_host=true; to_path="${to%%\?*}"
    elif _routes_host_is_app "$app" "$(_routes_url_host "$to")"; then
        same_host=true; to_path=$(_routes_url_path "$to"); to_path="${to_path%%[?#]*}"; to_path="${to_path:-/}"
    fi

    if $prefix && $keep; then
        [[ "$to" == *[?#]* ]] && { error "A prefix redirect that keeps the path cannot target ?query or #fragment — add --no-path"; exit 1; }
        [[ "$to" != */ ]] && to="${to}/"
        [[ "$to_path" != "" && "$to_path" != */ ]] && to_path="${to_path}/"
        if $same_host && [[ "$to_path" == "$from"* ]]; then
            error "${to} is inside ${from} — the redirect would loop"; exit 1
        fi
    elif $same_host; then
        if [[ "$to_path" == "$from" ]] || { $prefix && [[ "$to_path" == "$from"* ]]; }; then
            error "${to} matches ${from} again — the redirect would loop"; exit 1
        fi
    fi
    _routes_preflight || exit 1

    local before existed=false
    before=$(_routes_app_json "$app")
    vault_read apps.json | jq -e --arg a "$app" --arg f "$from" '(.[$a].redirects // []) | any(.from == $f)' >/dev/null 2>&1 && existed=true
    local rule; rule=$(jq -nc --arg f "$from" --arg t "$to" --argjson c "$code" --argjson k "$keep" \
        '{from: $f, to: $t, code: $c, keep_path: $k}')
    app_set_json "$app" redirects "$(vault_read apps.json | jq -c --arg a "$app" --argjson r "$rule" \
        '(.[$a].redirects // []) | map(select(.from != $r.from)) + [$r] | sort_by(.from)')"
    _routes_apply "$app" "$before" || exit 1

    local label="exact"; $prefix && label="prefix"
    _routes_notify redirect_change "$app" "REDIRECT $($existed && echo UPDATED || echo ADDED): ${app} ${from} → ${to} (${code}, ${label})"
    success "Redirect ${code}: ${from}$($prefix && $keep && echo '*') → ${to}$($prefix && $keep && echo '*')"
}

redirect_remove() {
    local app="${1:-}" from="${2:-}"
    _routes_require_app "$app" "cipi redirect remove <app> <from>"
    [[ -z "$from" ]] && { error "Usage: cipi redirect remove <app> <from>"; exit 1; }
    [[ "$from" != /* ]] && from="/${from}"
    if ! vault_read apps.json | jq -e --arg a "$app" --arg f "$from" '(.[$a].redirects // []) | any(.from == $f)' >/dev/null 2>&1; then
        error "No redirect from '${from}' on '${app}' (cipi redirect list ${app})"; exit 1
    fi
    _routes_preflight || exit 1

    local before; before=$(_routes_app_json "$app")
    app_set_json "$app" redirects "$(vault_read apps.json | jq -c --arg a "$app" --arg f "$from" \
        '(.[$a].redirects // []) | map(select(.from != $f))')"
    _routes_apply "$app" "$before" || exit 1
    _routes_notify redirect_change "$app" "REDIRECT REMOVED: ${app} ${from}"
    success "Redirect from ${from} removed"
}

# ══ cipi proxy ════════════════════════════════════════════════

proxy_command() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        add)            proxy_add "$@" ;;
        remove|rm)      proxy_remove "$@" ;;
        list|status|ls) routes_list proxy "$@" ;;
        *) error "Unknown: ${sub}"; echo "Use: add remove list"; exit 1 ;;
    esac
}

# Loopback ports that belong to something else on this server. Proxying a
# public prefix to one of them would publish it (a database, Meilisearch with
# its master key, another app's Octane/Reverb, or nginx itself — a loop).
_routes_reserved_local_port() {
    local app="$1" port="$2" p
    case "$port" in
        80|443) echo "nginx itself (proxy loop)"; return 0 ;;
        22)     echo "SSH"; return 0 ;;
        3306)   echo "MariaDB"; return 0 ;;
        5432)   echo "PostgreSQL"; return 0 ;;
        6379)   echo "Valkey"; return 0 ;;
    esac
    if [[ -f "${CIPI_CONFIG}/search.json" ]]; then
        p=$(vault_read search.json 2>/dev/null | jq -r '.port // empty' 2>/dev/null || true)
        [[ -n "$p" && "$p" == "$port" ]] && { echo "Meilisearch"; return 0; }
    fi
    p=$(vault_read apps.json | jq -r --arg a "$app" --arg p "$port" '
        to_entries[] | select(.key != $a) |
        select((.value.octane_port // "" | tostring) == $p or (.value.reverb_port // "" | tostring) == $p) |
        .key' 2>/dev/null | head -1)
    [[ -n "$p" ]] && { echo "app '${p}' (Octane/Reverb)"; return 0; }
    return 1
}

# cipi proxy add <app> <prefix> <upstream> [--strip-prefix] [--preserve-host]
#                [--timeout=60] [--no-buffering] [--force]
proxy_add() {
    local app="${1:-}" prefix="${2:-}" upstream="${3:-}"
    local usage="cipi proxy add <app> <prefix> <http(s)://upstream> [--strip-prefix] [--preserve-host] [--timeout=60] [--no-buffering]"
    _routes_require_app "$app" "$usage"
    [[ -z "$prefix" || -z "$upstream" || "$prefix" == --* || "$upstream" == --* ]] && { error "Usage: ${usage}"; exit 1; }
    shift 3
    parse_args "$@"

    [[ "$prefix" != /* ]] && prefix="/${prefix}"
    [[ "$prefix" != */ ]] && prefix="${prefix}/"
    _routes_valid_source_path "$prefix" || exit 1
    _routes_valid_upstream "$upstream" || { error "Invalid upstream '${upstream}' — expected http(s)://host[:port][/path]"; exit 1; }
    _routes_check_path "$app" "$prefix" proxy || exit 1

    local strip=false preserve=false buffering=true timeout="${ARG_timeout:-60}"
    [[ "${ARG_strip_prefix:-}" == "true" ]] && strip=true
    [[ "${ARG_preserve_host:-}" == "true" ]] && preserve=true
    [[ "${ARG_no_buffering:-}" == "true" ]] && buffering=false
    [[ "$timeout" =~ ^[0-9]{1,4}$ ]] && timeout=$((10#$timeout))
    if ! [[ "$timeout" =~ ^[0-9]+$ ]] || (( timeout < 1 || timeout > 3600 )); then
        error "--timeout must be 1-3600 seconds"; exit 1
    fi

    local up_path; up_path=$(_routes_url_path "$upstream")
    if [[ -n "$up_path" ]] && ! $strip; then
        error "An upstream with a path (${up_path}) replaces ${prefix} — add --strip-prefix, or drop the path to pass ${prefix} through"
        exit 1
    fi

    local host port what
    host=$(_routes_url_host "$upstream"); port=$(_routes_url_port "$upstream")
    if [[ "$host" == localhost || "$host" == 0.0.0.0 || "$host" =~ ^127\. ]]; then
        if what=$(_routes_reserved_local_port "$app" "$port"); then
            if [[ "${ARG_force:-}" != "true" ]]; then
                error "127.0.0.1:${port} is ${what} — publishing it under ${prefix} is almost certainly a mistake"
                error "If you really mean it: add --force"
                exit 1
            fi
            warn "Publishing ${what} (127.0.0.1:${port}) under ${prefix} (--force)"
        fi
    elif _routes_host_is_app "$app" "$host"; then
        error "'${host}' is this app — the proxy would loop"; exit 1
    fi
    _routes_preflight || exit 1

    # nginx resolves the upstream hostname once, at reload. Say so before a
    # reload fails on it, and warn (never block) when nothing answers yet.
    if [[ ! "$host" =~ ^[0-9.]+$ && "$host" != localhost ]] && ! getent hosts "$host" >/dev/null 2>&1; then
        error "'${host}' does not resolve — nginx resolves upstream names at reload and would refuse it"; exit 1
    fi
    if command -v curl >/dev/null 2>&1 && ! curl -sk -o /dev/null --max-time 5 "$upstream" 2>/dev/null; then
        warn "${upstream} did not answer within 5s — the route is added anyway (502 until it does)"
    fi

    local before existed=false
    before=$(_routes_app_json "$app")
    vault_read apps.json | jq -e --arg a "$app" --arg p "$prefix" '(.[$a].proxies // []) | any(.prefix == $p)' >/dev/null 2>&1 && existed=true
    local rule; rule=$(jq -nc --arg p "$prefix" --arg u "$upstream" --argjson s "$strip" --argjson h "$preserve" \
        --argjson t "$timeout" --argjson b "$buffering" \
        '{prefix: $p, upstream: $u, strip_prefix: $s, preserve_host: $h, timeout: $t, buffering: $b}')
    app_set_json "$app" proxies "$(vault_read apps.json | jq -c --arg a "$app" --argjson r "$rule" \
        '(.[$a].proxies // []) | map(select(.prefix != $r.prefix)) + [$r] | sort_by(.prefix)')"
    _routes_apply "$app" "$before" || exit 1

    _routes_notify proxy_change "$app" "PROXY $($existed && echo UPDATED || echo ADDED): ${app} ${prefix} → ${upstream}"
    local shown="${upstream%/}${prefix}"
    $strip && shown="${upstream%/}/"
    success "Proxy: $(domain_url_host "$(app_get "$app" domain)")${prefix}* → ${shown}*"
    if [[ "$(app_get "$app" basic_auth)" == "true" ]]; then
        info "Basic auth is on for '${app}' — it applies to ${prefix} too"
    fi
}

proxy_remove() {
    local app="${1:-}" prefix="${2:-}"
    _routes_require_app "$app" "cipi proxy remove <app> <prefix>"
    [[ -z "$prefix" ]] && { error "Usage: cipi proxy remove <app> <prefix>"; exit 1; }
    [[ "$prefix" != /* ]] && prefix="/${prefix}"
    [[ "$prefix" != */ ]] && prefix="${prefix}/"
    if ! vault_read apps.json | jq -e --arg a "$app" --arg p "$prefix" '(.[$a].proxies // []) | any(.prefix == $p)' >/dev/null 2>&1; then
        error "No proxy on '${prefix}' for '${app}' (cipi proxy list ${app})"; exit 1
    fi
    _routes_preflight || exit 1

    local before; before=$(_routes_app_json "$app")
    app_set_json "$app" proxies "$(vault_read apps.json | jq -c --arg a "$app" --arg p "$prefix" \
        '(.[$a].proxies // []) | map(select(.prefix != $p))')"
    _routes_apply "$app" "$before" || exit 1
    _routes_notify proxy_change "$app" "PROXY REMOVED: ${app} ${prefix}"
    success "Proxy on ${prefix} removed"
}

# ══ list (both commands) ══════════════════════════════════════

# routes_list redirect|proxy <app> [--json]
routes_list() {
    local kind="$1" app="${2:-}"
    _routes_require_app "$app" "cipi ${kind} list <app> [--json]"
    shift 2 || true
    parse_args "$@"

    local cfg
    cfg=$(vault_read apps.json | jq -c --arg a "$app" '{
        app: $a,
        redirect: (.[$a].redirect // null),
        redirects: (.[$a].redirects // []),
        proxies: (.[$a].proxies // []),
        suspended: (.[$a].suspended == "true")
    }')
    if [[ "${ARG_json:-}" == "true" ]]; then
        if [[ "$kind" == proxy ]]; then jq '{app, proxies}' <<< "$cfg"
        else jq '{app, redirect, redirects}' <<< "$cfg"; fi
        return 0
    fi

    echo -e "\n${BOLD}$([[ "$kind" == proxy ]] && echo Proxies || echo Redirects) — ${app}${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    [[ "$(jq -r '.suspended' <<< "$cfg")" == "true" ]] && echo -e "  ${YELLOW}App is suspended — nothing below is served until unsuspend${NC}"

    local line
    if [[ "$kind" == redirect ]]; then
        local r_enabled; r_enabled=$(jq -r '.redirect.enabled // empty' <<< "$cfg")
        if [[ -n "$r_enabled" ]]; then
            line=$(jq -r '.redirect | "\(.code) → \(.to)\(if .keep_path == false then "" else "<path>" end)"' <<< "$cfg")
            if [[ "$r_enabled" == "true" ]]; then
                printf "  %-10s ${GREEN}%s${NC}  %s\n" "App" "on" "$line"
            else
                printf "  %-10s ${DIM}%s${NC}  ${DIM}%s${NC}\n" "App" "off" "$line"
            fi
        else
            printf "  %-10s ${DIM}%s${NC}\n" "App" "none"
        fi
        echo ""
        if [[ "$(jq '.redirects | length' <<< "$cfg")" -eq 0 ]]; then
            echo -e "  ${DIM}No path redirects${NC}"
        else
            printf "  ${BOLD}%-5s %-8s %-30s %s${NC}\n" "CODE" "MATCH" "FROM" "TO"
            jq -r '.redirects[] | [
                (.code|tostring),
                (if (.from|endswith("/")) then "prefix" else "exact" end),
                (.from + (if (.from|endswith("/")) and .keep_path != false then "*" else "" end)),
                (.to + (if (.from|endswith("/")) and .keep_path != false then "*" else "" end))
            ] | @tsv' <<< "$cfg" | while IFS=$'\t' read -r c m f t; do
                printf "  ${CYAN}%-5s${NC} %-8s %-30s %s\n" "$c" "$m" "$f" "$t"
            done
        fi
    else
        if [[ "$(jq '.proxies | length' <<< "$cfg")" -eq 0 ]]; then
            echo -e "  ${DIM}No proxy routes${NC}"
        else
            printf "  ${BOLD}%-24s %-40s %s${NC}\n" "PREFIX" "UPSTREAM" "OPTIONS"
            jq -r '.proxies[] | [
                .prefix, .upstream,
                ([ (if .strip_prefix then "strip-prefix" else "keep-prefix" end),
                   (if .preserve_host then "preserve-host" else empty end),
                   ("timeout=\(.timeout // 60)s"),
                   (if .buffering == false then "no-buffering" else empty end)
                 ] | join(" "))
            ] | @tsv' <<< "$cfg" | while IFS=$'\t' read -r p u o; do
                printf "  ${CYAN}%-24s${NC} %-40s ${DIM}%s${NC}\n" "$p" "$u" "$o"
            done
        fi
        if [[ "$(jq -r '.redirect.enabled // false' <<< "$cfg")" == "true" ]]; then
            echo -e "\n  ${DIM}The app redirects everything else to $(jq -r '.redirect.to' <<< "$cfg")${NC}"
        fi
    fi
    echo ""
}
