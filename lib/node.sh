#!/bin/bash
#############################################
# Cipi — Node frontend apps and Node runtimes
#
#   cipi app create --node=spa|static|ssr [--framework=next|nuxt|sveltekit|astro|remix|vite]
#   cipi node install|list|upgrade|remove <major>
#   cipi node status|restart|logs <app>
#
# Three modes, one app type:
#   spa     a client-side app (Vite + React/Vue/Svelte…): built on deploy,
#           served by nginx, unknown paths fall back to /index.html
#   static  a pre-rendered site (Astro, Nuxt generate, Next export…): same, but
#           an unknown path is a real 404
#   ssr     a Node server (Next, Nuxt/Nitro, SvelteKit, Astro node, Remix):
#           two Supervisor programs on localhost ports (blue/green); a deploy
#           starts the new release on the idle one, waits for it to answer and
#           only then moves nginx (lib/cipi-node-switch.sh)
#
# In apps.json a Node app is `custom: true` plus `runtime: "node"`: everything
# that only makes sense for Laravel (artisan, Horizon, Reverb, Scout, the
# scheduler, the Laravel .env) already refuses custom apps. PHP is still there,
# for Deployer and for the webhook receiver's tiny FPM pool.
#
# Node itself comes from nodejs.org, one directory per major under
# /opt/cipi/node/<major>, checked against the release's SHASUMS256.txt. Apps on
# different majors run side by side. The system Node from NodeSource stays
# installed; `cipi node default` puts a managed major in front of it.
#############################################

[[ -z "${NODE_ROOT:-}" ]]        && readonly NODE_ROOT="/opt/cipi/node"
[[ -z "${NODE_STATE_DIR:-}" ]]   && readonly NODE_STATE_DIR="/var/lib/cipi/node"
[[ -z "${NODE_WEBHOOK_PHP:-}" ]] && readonly NODE_WEBHOOK_PHP="/usr/local/share/cipi/webhook.php"
[[ -z "${NODE_DIST_URL:-}" ]]    && readonly NODE_DIST_URL="https://nodejs.org/dist"
[[ -z "${NODE_DEFAULT_MAJOR:-}" ]] && readonly NODE_DEFAULT_MAJOR="22"
[[ -z "${NODE_PORT_MIN:-}" ]]    && readonly NODE_PORT_MIN=3100
[[ -z "${NODE_PORT_MAX:-}" ]]    && readonly NODE_PORT_MAX=3999
[[ -z "${NODE_SHIM_DIR:-}" ]]    && readonly NODE_SHIM_DIR="/usr/local/bin"
# What `cipi node default` links into /usr/local/bin, ahead of the NodeSource
# binaries in /usr/bin on every PATH an app sees (SSH, sudo secure_path, .bashrc).
[[ -z "${NODE_SHIMS:-}" ]]       && readonly NODE_SHIMS="node npm npx corepack pnpm pnpx yarn yarnpkg"

node_command() {
    local sub="${1:-list}"; shift || true
    case "$sub" in
        install)        _node_install_cmd "$@" ;;
        default)        _node_default_cmd "$@" ;;
        list|ls)        _node_list ;;
        upgrade|update) _node_upgrade_cmd "$@" ;;
        remove|rm)      _node_remove_cmd "$@" ;;
        status)         _node_status_cmd "$@" ;;
        restart)        _node_restart_cmd "$@" ;;
        logs|log)       _node_logs_cmd "$@" ;;
        *) error "Unknown: ${sub}"; echo "Use: install default list upgrade remove status restart logs"; exit 1 ;;
    esac
}

app_is_node() { [[ "$(app_get "$1" runtime 2>/dev/null)" == "node" ]]; }

# ── runtimes ──────────────────────────────────────────────────

_node_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo x64 ;;
        aarch64|arm64) echo arm64 ;;
        *) return 1 ;;
    esac
}

# Even (LTS) majors only.
_node_valid_major() { [[ "$1" =~ ^[2-9][0-9]$ ]] && (( $1 % 2 == 0 )); }

node_is_installed() { [[ -x "${NODE_ROOT}/${1}/bin/node" ]]; }

node_full_version() { "${NODE_ROOT}/${1}/bin/node" --version 2>/dev/null | tr -d 'v'; }

# Download the latest release of a major, verify it, install it next to the
# current one and switch the <major> symlink atomically — running processes
# keep the binary they started with until their next restart.
_node_install_major() {
    local major="$1" arch file sums sum tmp ver dir
    _node_valid_major "$major" || { error "Node major must be an even (LTS) version such as 22 or 24"; return 1; }
    arch=$(_node_arch) || { error "Unsupported CPU architecture: $(uname -m)"; return 1; }

    step "Node ${major}: looking up the latest release..."
    sums=$(curl -fsSL --max-time 30 "${NODE_DIST_URL}/latest-v${major}.x/SHASUMS256.txt") \
        || { error "Could not download ${NODE_DIST_URL}/latest-v${major}.x/SHASUMS256.txt"; return 1; }
    file=$(awk -v a="linux-${arch}.tar.xz" '$2 ~ "^node-v[0-9.]+-" a "$" { print $2; exit }' <<< "$sums")
    sum=$(awk -v f="$file" '$2 == f { print $1; exit }' <<< "$sums")
    [[ -n "$file" && "$sum" =~ ^[0-9a-f]{64}$ ]] || { error "No linux-${arch} build listed for Node ${major}"; return 1; }
    ver="${file#node-v}"; ver="${ver%%-linux-*}"
    dir="${NODE_ROOT}/v${ver}"

    if [[ -x "${dir}/bin/node" && "$(readlink -f "${NODE_ROOT}/${major}" 2>/dev/null)" == "$dir" ]]; then
        success "Node ${ver} is already installed"
        return 0
    fi

    tmp=$(mktemp -d)
    step "Downloading ${file}..."
    if ! curl -fsSL --max-time 600 -o "${tmp}/${file}" "${NODE_DIST_URL}/latest-v${major}.x/${file}"; then
        rm -rf "$tmp"; error "Download failed"; return 1
    fi
    if [[ "$(sha256sum "${tmp}/${file}" | awk '{print $1}')" != "$sum" ]]; then
        rm -rf "$tmp"; error "Checksum mismatch for ${file} — not installed"; return 1
    fi
    mkdir -p "$NODE_ROOT"
    rm -rf "${dir}.partial"
    mkdir -p "${dir}.partial"
    if ! tar -xJf "${tmp}/${file}" -C "${dir}.partial" --strip-components=1 --no-same-owner; then
        rm -rf "$tmp" "${dir}.partial"; error "Could not unpack ${file}"; return 1
    fi
    rm -rf "$tmp"
    chown -R root:root "${dir}.partial"
    chmod -R go-w "${dir}.partial"
    rm -rf "$dir"
    mv "${dir}.partial" "$dir"

    # pnpm and yarn through corepack, pinned by each project's packageManager.
    "${dir}/bin/corepack" enable --install-directory "${dir}/bin" >/dev/null 2>&1 \
        || warn "corepack enable failed — pnpm/yarn projects will not build on Node ${major}"

    ln -sfn "$dir" "${NODE_ROOT}/.${major}.new" && mv -Tf "${NODE_ROOT}/.${major}.new" "${NODE_ROOT}/${major}"
    chmod 755 "$NODE_ROOT"
    log_action "NODE INSTALLED: ${ver}"
    success "Node ${ver} → ${NODE_ROOT}/${major}"
}

# Versions of a major no longer pointed at by its symlink.
_node_prune_major() {
    local major="$1" keep d
    keep=$(readlink -f "${NODE_ROOT}/${major}" 2>/dev/null || true)
    for d in "${NODE_ROOT}"/v"${major}".*; do
        [[ -d "$d" && "$d" != "$keep" ]] || continue
        rm -rf "$d"
    done
}

# Apps with their own major (Node apps, pinned Laravel apps).
_node_apps_on() {
    vault_read apps.json 2>/dev/null | jq -r --arg m "$1" \
        'to_entries[] | select((.value.node_version // "" | tostring) == $m) | .key' 2>/dev/null || true
}

# ── server-wide default (Laravel apps, cipi app run, anything on PATH) ──

# The major /usr/local/bin/node points at, or empty when the system Node
# (NodeSource, /usr/bin) is in use.
node_default_major() {
    local t; t=$(readlink "${NODE_SHIM_DIR}/node" 2>/dev/null || true)
    [[ "$t" =~ ^${NODE_ROOT}/([0-9]{2})/bin/node$ ]] && printf '%s' "${BASH_REMATCH[1]}"
    return 0
}

# bin directory an app's npm/node run from: its own major (Node apps, or a
# Laravel app pinned with --node-version), else the server default, else empty
# (system Node).
node_bin_for_app() {
    local v; v=$(app_get "$1" node_version 2>/dev/null)
    [[ -z "$v" ]] && v=$(node_default_major)
    [[ -n "$v" && -d "${NODE_ROOT}/${v}/bin" ]] && printf '%s' "${NODE_ROOT}/${v}/bin"
    return 0
}

_node_is_our_shim() { [[ -L "$1" && "$(readlink "$1")" == "${NODE_ROOT}/"* ]]; }

# cipi node default [<major>|system]
_node_default_cmd() {
    local want="${1:-}" cur shim target
    cur=$(node_default_major)
    if [[ -z "$want" ]]; then
        if [[ -n "$cur" ]]; then
            echo -e "Server default: ${CYAN}Node ${cur}${NC} ($(node_full_version "$cur")) — ${NODE_ROOT}/${cur}"
        else
            echo -e "Server default: ${CYAN}system Node${NC} ($(/usr/bin/node --version 2>/dev/null || echo 'not installed'), /usr/bin)"
        fi
        return 0
    fi

    if [[ "$want" == "system" ]]; then
        [[ -n "$cur" ]] || { info "The system Node is already the default"; return 0; }
        for shim in $NODE_SHIMS; do
            _node_is_our_shim "${NODE_SHIM_DIR}/${shim}" && rm -f "${NODE_SHIM_DIR}/${shim}"
        done
        hash -r 2>/dev/null || true
        log_action "NODE DEFAULT: system (was ${cur})"
        _node_default_notify "system Node ($(/usr/bin/node --version 2>/dev/null || echo 'not installed'))" "$cur"
        success "Server default → system Node $(/usr/bin/node --version 2>/dev/null)"
        return 0
    fi

    _node_valid_major "$want" || { error "Usage: cipi node default <major>|system  (even majors such as 22 or 24)"; exit 1; }
    node_is_installed "$want" || _node_install_major "$want" || exit 1
    local skipped=""
    for shim in $NODE_SHIMS; do
        target="${NODE_ROOT}/${want}/bin/${shim}"
        if [[ ! -e "$target" ]]; then
            _node_is_our_shim "${NODE_SHIM_DIR}/${shim}" && rm -f "${NODE_SHIM_DIR}/${shim}"
            continue
        fi
        # Never replace something Cipi did not put there (a global pnpm, a
        # hand-installed node): say so instead.
        if [[ -e "${NODE_SHIM_DIR}/${shim}" || -L "${NODE_SHIM_DIR}/${shim}" ]] && ! _node_is_our_shim "${NODE_SHIM_DIR}/${shim}"; then
            skipped="${skipped} ${shim}"
            continue
        fi
        ln -sfn "$target" "${NODE_SHIM_DIR}/.${shim}.cipi-new" && mv -Tf "${NODE_SHIM_DIR}/.${shim}.cipi-new" "${NODE_SHIM_DIR}/${shim}"
    done
    hash -r 2>/dev/null || true
    [[ -n "$skipped" ]] && warn "Left alone (not managed by Cipi):${skipped} — in ${NODE_SHIM_DIR}"
    log_action "NODE DEFAULT: ${want} (was ${cur:-system})"
    _node_default_notify "Node ${want} ($(node_full_version "$want"))" "${cur:-system}"
    success "Server default → Node $(node_full_version "$want")"
    echo -e "  ${DIM}Laravel asset builds, cipi app run npm and cipi.yml deploy.post use it from the next run.${NC}"
    local pinned; pinned=$(vault_read apps.json 2>/dev/null | jq -r 'to_entries[] | select((.value.runtime // "") != "node" and (.value.node_version // "") != "") | "\(.key) (\(.value.node_version))"' | paste -sd, -)
    [[ -n "$pinned" ]] && echo -e "  ${DIM}Pinned to their own major, unchanged: ${pinned}${NC}"
    echo -e "  ${DIM}Node apps keep their own version (cipi app edit <app> --node-version=…).${NC}"
}

_node_default_notify() {
    cipi_notify \
        "Cipi Node default changed on $(hostname)" \
        "The server-wide Node version changed.\n\nServer: $(hostname)\nNow: $1\nBefore: Node $2\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        node_default 2>/dev/null || true
}

_node_install_cmd() {
    local major="${1:-$NODE_DEFAULT_MAJOR}"
    _node_install_major "$major" || exit 1
}

_node_list() {
    echo -e "\n${BOLD}Node runtimes${NC} ${DIM}(${NODE_ROOT})${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local l major found=false
    local def; def=$(node_default_major)
    for l in "${NODE_ROOT}"/[0-9]*; do
        [[ -L "$l" ]] || continue
        found=true
        major=$(basename "$l")
        printf "  %-6s ${CYAN}%-10s${NC} %-10s %s\n" "$major" "$(node_full_version "$major" || echo '?')" \
            "$([[ "$major" == "$def" ]] && echo default)" "$(_node_apps_on "$major" | paste -sd, - | sed 's/^$/-/')"
    done
    $found || echo -e "  ${DIM}None — cipi node install ${NODE_DEFAULT_MAJOR}${NC}"
    if [[ -x /usr/bin/node ]]; then
        printf "  %-6s ${CYAN}%-10s${NC} %s\n" "system" "$(/usr/bin/node --version 2>/dev/null | tr -d v)" "$([[ -z "$def" ]] && echo default)"
    fi
    echo -e "\n  ${DIM}Server default (Laravel builds, cipi app run): cipi node default <major>|system${NC}"
    echo ""
}

# cipi node upgrade [major] [--restart] — latest patch; SSR apps keep the old
# binary until restarted (zero-downtime with --restart).
_node_upgrade_cmd() {
    local major="${1:-}"; shift || true
    [[ "$major" == --* ]] && { set -- "$major" "$@"; major=""; }
    parse_args "$@"
    local majors=() l
    if [[ -n "$major" ]]; then
        majors=("$major")
    else
        for l in "${NODE_ROOT}"/[0-9]*; do [[ -L "$l" ]] && majors+=("$(basename "$l")"); done
    fi
    [[ ${#majors[@]} -gt 0 ]] || { info "No Node runtime installed"; return 0; }
    local m app
    for m in "${majors[@]}"; do
        node_is_installed "$m" || { error "Node ${m} is not installed"; continue; }
        _node_install_major "$m" || continue
        for app in $(_node_apps_on "$m"); do
            [[ "$(app_get "$app" node_mode)" == "ssr" ]] || continue
            if [[ "${ARG_restart:-}" == "true" ]]; then
                step "Restarting ${app} on the new binary (blue/green)..."
                /usr/local/bin/cipi-node-switch "$app" current || warn "${app}: restart failed — still on the previous process"
            else
                info "${app} picks up $(node_full_version "$m") on its next deploy or: cipi node restart ${app}"
            fi
        done
        [[ "${ARG_restart:-}" == "true" ]] && _node_prune_major "$m"
    done
}

_node_remove_cmd() {
    local major="${1:-}"
    _node_valid_major "$major" || { error "Usage: cipi node remove <major>"; exit 1; }
    local users; users=$(_node_apps_on "$major" | paste -sd, -)
    [[ -z "$users" ]] || { error "Node ${major} is used by: ${users}"; exit 1; }
    [[ "$(node_default_major)" != "$major" ]] || { error "Node ${major} is the server default — first: cipi node default <other major>|system"; exit 1; }
    [[ -L "${NODE_ROOT}/${major}" ]] || { info "Node ${major} is not installed"; return 0; }
    local dir; dir=$(readlink -f "${NODE_ROOT}/${major}")
    rm -f "${NODE_ROOT}/${major}"
    [[ "$dir" == "${NODE_ROOT}/v"* ]] && rm -rf "$dir"
    _node_prune_major "$major"
    log_action "NODE REMOVED: ${major}"
    success "Node ${major} removed"
}

# ── app options ───────────────────────────────────────────────

# Framework presets: mode|build|start|output. Every value can be overridden.
_node_preset() {
    case "$1" in
        next)       echo "ssr|npm run build|npx next start -H 127.0.0.1|" ;;
        nuxt)       echo "ssr|npm run build|node .output/server/index.mjs|" ;;
        sveltekit)  echo "ssr|npm run build|node build|" ;;
        astro)      echo "ssr|npm run build|node ./dist/server/entry.mjs|" ;;
        remix)      echo "ssr|npm run build|npm run start|" ;;
        vite)       echo "spa|npm run build||dist" ;;
        *) return 1 ;;
    esac
}

# A start command runs as argv, never through a shell: a runner and plain words.
_node_valid_start() {
    local cmd="$1" w n=0
    [[ -n "$cmd" && ${#cmd} -le 200 ]] || return 1
    [[ "$cmd" == *..* ]] && return 1
    for w in $cmd; do
        n=$((n + 1))
        [[ "$w" =~ ^[A-Za-z0-9@._/:=+-]+$ ]] || return 1
        if [[ $n -eq 1 ]]; then
            case "$w" in node|npm|npx|pnpm|yarn|bun) ;; *) return 1 ;; esac
        fi
    done
    (( n >= 2 && n <= 12 ))
}

# Build output served by nginx: a directory inside the release, never its root.
_node_valid_output() {
    local o="${1%/}" seg
    [[ "$o" =~ ^[A-Za-z0-9_.][A-Za-z0-9._/-]{0,120}$ ]] || return 1
    [[ "$o" == *..* || "$o" == *//* || "$o" == . ]] && return 1
    # .output/public (Nuxt) is fine; the repository, secrets and dependencies are not.
    local IFS=/
    for seg in $o; do
        case "$seg" in .git|.git*|.env|.env*|.ssh|node_modules) return 1 ;; esac
    done
    return 0
}

_node_valid_health() { [[ "$1" =~ ^/[A-Za-z0-9._~/-]{0,200}$ ]]; }

_node_valid_mode() { [[ "$1" =~ ^(spa|static|ssr)$ ]]; }

# Resolve --node / --framework / --build / --start / --output / --health-path /
# --node-version into NODE_OPT_* (create), refusing anything invalid.
_node_resolve_create_opts() {
    local mode="${ARG_node:-}" fw="${ARG_framework:-}" preset=""
    [[ "$mode" == "true" ]] && mode=""
    NODE_OPT_FRAMEWORK="$fw"
    if [[ -n "$fw" ]]; then
        preset=$(_node_preset "$fw") || { error "Unknown --framework '${fw}'. Use: next nuxt sveltekit astro remix vite"; return 1; }
    fi
    local p_mode p_build p_start p_output
    IFS='|' read -r p_mode p_build p_start p_output <<< "$preset"
    NODE_OPT_MODE="${mode:-${p_mode:-spa}}"
    NODE_OPT_BUILD="${ARG_build:-${p_build:-npm run build}}"
    NODE_OPT_START="${ARG_start:-${p_start:-npm run start}}"
    NODE_OPT_OUTPUT="${ARG_output:-${p_output:-dist}}"
    NODE_OPT_HEALTH="${ARG_health_path:-/}"
    local server_default; server_default=$(node_default_major)
    NODE_OPT_VERSION="${ARG_node_version:-${server_default:-$NODE_DEFAULT_MAJOR}}"

    _node_valid_mode "$NODE_OPT_MODE" || { error "--node must be spa, static or ssr"; return 1; }
    _node_valid_major "$NODE_OPT_VERSION" || { error "--node-version must be an even (LTS) major such as 22 or 24"; return 1; }
    _validate_node_build_cmd "$NODE_OPT_BUILD" && [[ -n "$NODE_OPT_BUILD" ]] \
        || { error "Invalid --build. Use npm/npx/yarn/pnpm/bun/node and safe characters only."; return 1; }
    if [[ "$NODE_OPT_MODE" == "ssr" ]]; then
        _node_valid_start "$NODE_OPT_START" \
            || { error "Invalid --start. A runner (node npm npx pnpm yarn bun) and plain arguments, no shell syntax."; return 1; }
        _node_valid_health "$NODE_OPT_HEALTH" || { error "Invalid --health-path"; return 1; }
        NODE_OPT_OUTPUT=""
    else
        _node_valid_output "$NODE_OPT_OUTPUT" || { error "Invalid --output: a directory inside the repository, e.g. dist"; return 1; }
        NODE_OPT_START=""
    fi
    return 0
}

_node_allocate_ports() {
    local used p a="" b=""
    used=$(vault_read apps.json 2>/dev/null | jq -r '.[] | (.node_ports // [])[] | tostring' 2>/dev/null || true)
    for p in $(seq "$NODE_PORT_MIN" "$NODE_PORT_MAX"); do
        grep -qx "$p" <<< "$used" && continue
        ss -ltn 2>/dev/null | grep -qE ":${p}\s" && continue
        if [[ -z "$a" ]]; then a="$p"; else b="$p"; break; fi
    done
    [[ -n "$a" && -n "$b" ]] || return 1
    printf '%s %s' "$a" "$b"
}

# ── server-side state ─────────────────────────────────────────

# /var/lib/cipi/node/<app>.json — what cipi-node-switch (root) acts on. Rewritten
# from apps.json on every config change; the live slot and releases are kept.
_node_state_write() {
    local app="$1" cur="{}" state host
    mkdir -p "$NODE_STATE_DIR"; chmod 700 "$NODE_STATE_DIR"
    [[ -f "${NODE_STATE_DIR}/${app}.json" ]] && cur=$(cat "${NODE_STATE_DIR}/${app}.json")
    host=$(domain_url_host "$(app_get "$app" domain)")
    state=$(vault_read apps.json | jq -c --arg a "$app" --arg h "$host" --argjson cur "$cur" '.[$a] | {
        app: $a,
        mode: .node_mode,
        version: (.node_version | tostring),
        start: (.node_start // ""),
        health: (.node_health // "/"),
        health_timeout: ((.node_health_timeout // 60) | tonumber),
        drain: 5,
        ports: ((.node_ports // []) | map(tonumber)),
        domain: $h,
        active: ($cur.active // -1),
        releases: ($cur.releases // ["", ""])
    }')
    [[ -n "$state" ]] || return 1
    (umask 077; printf '%s\n' "$state" > "${NODE_STATE_DIR}/${app}.json")
}

_node_upstream_ensure() {
    local app="$1" f="/etc/nginx/conf.d/cipi-node-${app}.conf" port
    [[ -f "$f" ]] && return 0
    port=$(vault_read apps.json | jq -r --arg a "$app" '.[$a].node_ports[0] // empty')
    [[ -n "$port" ]] || return 0
    printf 'upstream cipi_node_%s {\n    server 127.0.0.1:%s;\n    keepalive 16;\n}\n' "$app" "$port" > "$f"
    chmod 644 "$f"
}

# PHP-FPM pool that exists only for the webhook receiver: on demand, two
# children at most, open_basedir limited to the app's home and the receiver.
_node_webhook_pool() {
    local app="$1" v="$2"
    cat > "/etc/php/${v}/fpm/pool.d/${app}.conf" <<EOF
[${app}]
; Cipi — webhook receiver only (Node app). The site itself is not PHP.
user = ${app}
group = ${app}
listen = /run/php/${app}.sock
listen.owner = ${app}
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 2
pm.process_idle_timeout = 20s
pm.max_requests = 200
security.limit_extensions = .php
php_admin_value[open_basedir] = /home/${app}/:$(dirname "$NODE_WEBHOOK_PHP")/:/tmp/
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec
php_admin_value[upload_max_filesize] = 2M
php_admin_value[post_max_size] = 2M
php_admin_flag[log_errors] = on
php_admin_value[error_log] = /home/${app}/logs/webhook-error.log
EOF
}

_node_webhook_install_receiver() {
    if [[ ! -f "${CIPI_LIB}/cipi-webhook.php" ]]; then
        [[ -f "$NODE_WEBHOOK_PHP" ]]; return
    fi
    install -d -m 755 -o root -g root "$(dirname "$NODE_WEBHOOK_PHP")"
    install -m 644 -o root -g root "${CIPI_LIB}/cipi-webhook.php" "$NODE_WEBHOOK_PHP"
}

# ~/.cipi/webhook.json — the secret and branch, readable by the app user only.
_node_webhook_config() {
    local app="$1" dir="/home/${1}/.cipi"
    mkdir -p "$dir"
    vault_read apps.json | jq -c --arg a "$app" '.[$a] | {token: (.webhook_token // ""), branch: (.branch // "main")}' \
        > "${dir}/webhook.json"
    chown -R "${app}:${app}" "$dir"
    chmod 700 "$dir"; chmod 600 "${dir}/webhook.json"
}

# ── nginx ─────────────────────────────────────────────────────

# $1=app $2=server_name list $3=www redirect block $4=auth block $5=route blocks $6=cipi.yml deny
_node_nginx_vhost() {
    local app="$1" names="$2" www_block="$3" auth="$4" routes="$5" deny="$6"
    local mode output
    mode=$(app_get "$app" node_mode)
    output=$(app_get "$app" node_output)
    local webhook="    location = /cipi/webhook {
        limit_except POST { deny all; }
        client_max_body_size 2m;
        fastcgi_pass unix:/run/php/${app}.sock;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME ${NODE_WEBHOOK_PHP};
        fastcgi_param CIPI_APP ${app};
    }
"
    local headers='        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
'

    if [[ "$mode" == "ssr" ]]; then
        _ensure_nginx_octane_map
        _node_upstream_ensure "$app"
        cat > "/etc/nginx/sites-available/${app}" <<EOF
${www_block}server {
    listen 80;
    listen [::]:80;
    server_name ${names};
    root /var/www/html;
    access_log /home/${app}/logs/nginx-access.log;
    error_log /home/${app}/logs/nginx-error.log;
    client_max_body_size 64M;
${webhook}${routes}    location / {
${auth}        proxy_pass http://cipi_node_${app};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 300;
    }
${deny}
}
EOF
        return 0
    fi

    local fallback='try_files $uri $uri/ /index.html;' not_found=""
    if [[ "$mode" == "static" ]]; then
        fallback='try_files $uri $uri/ $uri.html =404;'
        not_found="    error_page 404 /404.html;"$'\n'
    fi
    cat > "/etc/nginx/sites-available/${app}" <<EOF
${www_block}server {
    listen 80;
    listen [::]:80;
    server_name ${names};
    root /home/${app}/current/${output};
    index index.html;
    access_log /home/${app}/logs/nginx-access.log;
    error_log /home/${app}/logs/nginx-error.log;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    client_max_body_size 16M;
${webhook}${routes}    location / {
${auth}        ${fallback}
    }
    # HTML is revalidated on every visit, so a deploy is picked up at once.
    location ~* \.html\$ {
${auth}${headers}        add_header Cache-Control "no-cache" always;
        try_files \$uri =404;
    }
    # Fingerprinted build assets (Vite, Astro, Nuxt, SvelteKit, CRA) never change.
    location ~* ^/(assets|_astro|_nuxt|_app/immutable|static)/ {
${auth}${headers}        add_header Cache-Control "public, max-age=31536000, immutable" always;
        access_log off;
        try_files \$uri =404;
    }
${deny}
    location ~ /\.(?!well-known) { deny all; }
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }
${not_found}}
EOF
}

# ~/.deployer/node.json — what the recipe reads right before install and build:
# the mode, the Node major and the build output. Rewritten whenever those change
# (create, app edit, cipi.yml at deploy time). The build command itself lives in
# node-build.sh; start command and ports stay in the root-only state file.
_node_recipe_config_write() {
    local app="$1" f="/home/${1}/.deployer/node.json"
    mkdir -p "/home/${app}/.deployer"
    # Laravel apps pinned with --node-version get {version} only; without a pin
    # the file goes away and they follow the server default.
    if [[ "$(app_get "$app" runtime)" != "node" ]]; then
        if [[ -z "$(app_get "$app" node_version)" ]]; then rm -f "$f"; return 0; fi
    fi
    vault_read apps.json | jq -c --arg a "$app" '.[$a] | if .runtime == "node" then {
        mode: (.node_mode // "spa"), version: (.node_version // "" | tostring), output: (.node_output // "")
    } else {version: (.node_version | tostring)} end' > "${f}.tmp" && mv -f "${f}.tmp" "$f"
    chown "${app}:${app}" "$f" 2>/dev/null || true
    chmod 644 "$f"
}

# The node settings a cipi.yml `node:` section asks for, merged over what the
# app has: framework preset first, explicit keys on top, current values for the
# rest. $1=app $2=the validated `node` object (JSON). Prints the result as JSON
# ({node_mode, node_version, node_build, node_start, node_output, node_health,
# node_framework}) or refuses with error() and returns 1.
_node_desired_from_yml() {
    local app="$1" nj="$2" cur fw preset="" p_mode="" p_build="" p_start="" p_output=""
    cur=$(vault_read apps.json | jq -c --arg a "$app" '.[$a]')
    fw=$(jq -r '.framework // empty' <<< "$nj")
    if [[ -n "$fw" ]]; then
        preset=$(_node_preset "$fw") || { error "node.framework '${fw}' is not one of: next nuxt sveltekit astro remix vite"; return 1; }
        IFS='|' read -r p_mode p_build p_start p_output <<< "$preset"
    fi
    pick() { # $1=yml key $2=preset value $3=current key $4=default
        local v; v=$(jq -r --arg k "$1" '.[$k] // empty | tostring' <<< "$nj")
        [[ -n "$v" ]] && { printf '%s' "$v"; return; }
        [[ -n "$fw" && -n "$2" ]] && { printf '%s' "$2"; return; }
        v=$(jq -r --arg k "$3" '.[$k] // empty | tostring' <<< "$cur")
        printf '%s' "${v:-$4}"
    }
    local mode version build start output health
    mode=$(pick mode "$p_mode" node_mode spa)
    version=$(pick version "" node_version "$NODE_DEFAULT_MAJOR")
    build=$(pick build "$p_build" node_build "npm run build")
    start=$(pick start "$p_start" node_start "npm run start")
    output=$(pick output "$p_output" node_output dist)
    health=$(pick health_path "" node_health /)
    unset -f pick

    _node_valid_mode "$mode" || { error "node.mode must be spa, static or ssr"; return 1; }
    _node_valid_major "$version" || { error "node.version must be an even (LTS) major such as 22 or 24"; return 1; }
    { _validate_node_build_cmd "$build" && [[ -n "$build" ]]; } || { error "node.build: npm/npx/yarn/pnpm/bun/node and safe characters only"; return 1; }
    if [[ "$mode" == "ssr" ]]; then
        _node_valid_start "$start" || { error "node.start: a Node runner (node npm npx pnpm yarn bun) and plain arguments"; return 1; }
        _node_valid_health "$health" || { error "node.health_path is not a valid path"; return 1; }
    else
        _node_valid_output "$output" || { error "node.output: a directory inside the repository, e.g. dist"; return 1; }
    fi
    [[ -z "$fw" ]] && fw=$(jq -r '.node_framework // empty' <<< "$cur")
    jq -nc --arg m "$mode" --arg v "$version" --arg b "$build" --arg s "$start" --arg o "$output" \
        --arg h "$health" --arg f "$fw" \
        '{node_mode: $m, node_version: $v, node_build: $b, node_start: $s, node_output: $o, node_health: $h, node_framework: $f}'
}

# "key: old → new" lines between the app's node settings and a desired object.
# Only the fields that matter for the mode are compared.
_node_desired_diff() {
    local app="$1" want="$2"
    vault_read apps.json | jq -r --arg a "$app" --argjson w "$want" '
        .[$a] as $c
        | ($w.node_mode) as $m
        | ["node_mode", "node_version", "node_build", "node_framework"]
          + (if $m == "ssr" then ["node_start", "node_health"] else ["node_output"] end)
        | .[]
        | . as $k
        | (($c[$k] // "") | tostring) as $old
        | (($w[$k] // "") | tostring) as $new
        | select($old != $new)
        | "\($k | sub("^node_"; "")): \(if $old == "" then "-" else $old end) → \(if $new == "" then "-" else $new end)"'
}

# ── lifecycle hooks used by lib/app.sh ────────────────────────

node_app_cleanup() {
    local app="$1"
    [[ -f "${NODE_STATE_DIR}/${app}.json" ]] && /usr/local/bin/cipi-node-switch "$app" --stop >/dev/null 2>&1 || true
    supervisorctl stop "${app}-node-blue" "${app}-node-green" >/dev/null 2>&1 || true
    rm -f "/etc/supervisor/conf.d/${app}-node.conf"
    rm -f "/etc/nginx/conf.d/cipi-node-${app}.conf"
    rm -f "${NODE_STATE_DIR}/${app}.json"
}

# ── per-app commands ──────────────────────────────────────────

_node_require_app() {
    local app="$1" usage="$2"
    [[ -n "$app" ]] || { error "Usage: ${usage}"; exit 1; }
    app_exists "$app" || { error "App '${app}' not found"; exit 1; }
    app_is_node "$app" || { error "'${app}' is not a Node app"; exit 1; }
}

_node_status_cmd() {
    local app="${1:-}"
    _node_require_app "$app" "cipi node status <app>"
    local mode ver
    mode=$(app_get "$app" node_mode); ver=$(app_get "$app" node_version)
    echo -e "\n${BOLD}Node — ${app}${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-10s ${CYAN}%s${NC}\n" "Mode" "$mode"
    printf "  %-10s ${CYAN}%s${NC} %s\n" "Node" "$ver" "$(node_is_installed "$ver" && node_full_version "$ver" || echo "(not installed)")"
    printf "  %-10s ${CYAN}%s${NC}\n" "Build" "$(app_get "$app" node_build)"
    if [[ "$mode" == "ssr" ]]; then
        printf "  %-10s ${CYAN}%s${NC}\n" "Start" "$(app_get "$app" node_start)"
        printf "  %-10s ${CYAN}%s${NC}\n" "Health" "$(app_get "$app" node_health)"
        echo ""
        /usr/local/bin/cipi-node-switch "$app" --status 2>/dev/null | sed 's/^/  /'
    else
        printf "  %-10s ${CYAN}%s${NC}\n" "Output" "$(app_get "$app" node_output)"
    fi
    [[ -L "/home/${app}/current" ]] && printf "\n  %-10s ${CYAN}%s${NC}\n" "Release" "$(basename "$(readlink -f "/home/${app}/current")")"
    echo ""
}

_node_restart_cmd() {
    local app="${1:-}"
    _node_require_app "$app" "cipi node restart <app>"
    if [[ "$(app_get "$app" node_mode)" != "ssr" ]]; then
        info "'${app}' is served by nginx (no Node process) — nothing to restart"; return 0
    fi
    [[ -L "/home/${app}/current" ]] || { error "'${app}' has no release yet — deploy first: cipi deploy ${app}"; exit 1; }
    _node_state_write "$app"
    /usr/local/bin/cipi-node-switch "$app" current || exit 1
    log_action "NODE RESTART: ${app}"
    success "'${app}' restarted with no downtime"
}

_node_logs_cmd() {
    local app="${1:-}"; shift || true
    _node_require_app "$app" "cipi node logs <app> [--lines=100]"
    parse_args "$@"
    local lines="${ARG_lines:-100}" active slot
    [[ "$lines" =~ ^[0-9]{1,5}$ ]] || lines=100
    active=$(jq -r '.active // -1' "${NODE_STATE_DIR}/${app}.json" 2>/dev/null || echo -1)
    slot=blue; [[ "$active" == 1 ]] && slot=green
    tail -n "$lines" "/home/${app}/logs/node-${slot}.log" 2>/dev/null || info "No log yet (/home/${app}/logs/node-${slot}.log)"
}
