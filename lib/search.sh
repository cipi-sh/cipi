#!/bin/bash
#############################################
# Cipi — Meilisearch (opt-in search engine for Laravel Scout)
#
# Off by default: neither setup.sh nor `cipi self-update` installs it, and
# nothing here runs unless someone types `cipi search install`.
#
# Native, not containerised. Meilisearch is a single static Rust binary with
# no runtime dependencies, so it installs the way the rest of the Cipi stack
# does: a binary, a config file, a systemd unit. Anything that needs a runtime
# around it belongs in the container branch, not here.
#
# Isolation model — one shared instance, logical separation:
#   * one process on 127.0.0.1 (never a public listener, no firewall hole),
#   * the master key lives in the vault and in a root-only EnvironmentFile,
#     never in an app .env and never on a command line,
#   * every app gets its own API key scoped to the index pattern "<app>-*"
#     with the actions Scout needs and nothing else,
#   * SCOUT_PREFIX=<app>- is written by Cipi, not left to the operator.
#
# The prefix is safe as an isolation boundary because a Cipi app username is
# ^[a-z][a-z0-9]{2,31}$ — no hyphens. So "blog-" can never be a prefix of
# "blogs-" or vice versa, and an index name always belongs to exactly one app.
# If an app ignores SCOUT_PREFIX, Meilisearch answers 403: it fails closed.
#
# An index is derived data (scout:import rebuilds it), so Meilisearch is
# deliberately absent from `cipi backup` and an upgrade is allowed to drop
# data.ms as a last resort.
#############################################

[[ -z "${SEARCH_CFG:-}" ]]           && readonly SEARCH_CFG="search.json"
[[ -z "${SEARCH_ENV_FILE:-}" ]]      && readonly SEARCH_ENV_FILE="${CIPI_CONFIG}/meilisearch.env"
[[ -z "${SEARCH_TOML:-}" ]]          && readonly SEARCH_TOML="/etc/meilisearch.toml"
[[ -z "${SEARCH_BIN:-}" ]]           && readonly SEARCH_BIN="/usr/local/bin/meilisearch"
[[ -z "${SEARCH_HOME:-}" ]]          && readonly SEARCH_HOME="/var/lib/meilisearch"
[[ -z "${SEARCH_UNIT:-}" ]]          && readonly SEARCH_UNIT="meilisearch"
[[ -z "${SEARCH_UNIT_FILE:-}" ]]     && readonly SEARCH_UNIT_FILE="/etc/systemd/system/meilisearch.service"
[[ -z "${SEARCH_DROPIN_DIR:-}" ]]    && readonly SEARCH_DROPIN_DIR="/etc/systemd/system/meilisearch.service.d"
[[ -z "${SEARCH_UPGRADE_DROPIN:-}" ]] && readonly SEARCH_UPGRADE_DROPIN="${SEARCH_DROPIN_DIR}/zz-cipi-upgrade.conf"
[[ -z "${SEARCH_SYS_USER:-}" ]]      && readonly SEARCH_SYS_USER="meilisearch"
# Never anything but loopback. A public Meilisearch is an unauthenticated-by-
# accident document store one misconfigured key away from a data leak, and the
# whole point of the scoped keys below is that they are handed to local apps.
[[ -z "${SEARCH_HOST:-}" ]]          && readonly SEARCH_HOST="127.0.0.1"
[[ -z "${SEARCH_DEFAULT_PORT:-}" ]]  && readonly SEARCH_DEFAULT_PORT=7700
[[ -z "${SEARCH_REPO:-}" ]]          && readonly SEARCH_REPO="meilisearch/meilisearch"
# Meilisearch memory-maps its LMDB store, so RSS understates what it really
# wants. On a 1GB VPS already running MariaDB tuned to that RAM, the OOM killer
# is a real outcome — and it does not always pick Meilisearch.
[[ -z "${SEARCH_MIN_RAM_KB:-}" ]]    && readonly SEARCH_MIN_RAM_KB=524288
[[ -z "${SEARCH_WARN_RAM_KB:-}" ]]   && readonly SEARCH_WARN_RAM_KB=1048576
[[ -z "${SEARCH_MIN_DISK_KB:-}" ]]   && readonly SEARCH_MIN_DISK_KB=1048576
[[ -z "${SEARCH_HEALTH_TIMEOUT:-}" ]] && readonly SEARCH_HEALTH_TIMEOUT=60
# Exactly what Laravel Scout calls, and nothing more. keys.* is deliberately
# absent: an app able to mint keys could mint one for another app's prefix.
[[ -z "${SEARCH_KEY_ACTIONS:-}" ]]   && readonly SEARCH_KEY_ACTIONS='["search","documents.*","indexes.*","settings.get","settings.update","tasks.get","stats.get"]'

search_command() {
    local sub="${1:-status}"; shift || true
    case "$sub" in
        install)          _search_install "$@" ;;
        status|info)      _search_status "$@" ;;
        list|apps)        _search_list "$@" ;;
        enable)           _search_enable "$@" ;;
        disable)          _search_disable "$@" ;;
        key|keys)         _search_key_cmd "$@" ;;
        upgrade)          _search_upgrade "$@" ;;
        remove|uninstall) _search_remove "$@" ;;
        help|--help|-h)   show_help search ;;
        *)
            error "Unknown search subcommand: ${sub}"
            echo -e "  Usage: ${CYAN}cipi search install|status|enable <app>|disable <app>|list|key|upgrade|remove${NC}"
            exit 1
            ;;
    esac
}

# ── state ────────────────────────────────────────────────────

_search_cfg() { vault_read "$SEARCH_CFG" 2>/dev/null || echo '{}'; }

_search_cfg_save() { vault_write "$SEARCH_CFG" 600; }

_search_installed() {
    [[ -x "$SEARCH_BIN" ]] && systemd_unit_exists "$SEARCH_UNIT"
}

_search_running() {
    systemctl is-active --quiet "$SEARCH_UNIT" 2>/dev/null
}

_search_port() {
    local p; p=$(_search_cfg | jq -r '.port // empty')
    [[ -n "$p" ]] && printf '%s' "$p" || printf '%s' "$SEARCH_DEFAULT_PORT"
}

_search_url() { printf 'http://%s:%s' "$SEARCH_HOST" "$(_search_port)"; }

_search_master_key() { _search_cfg | jq -r '.master_key // empty'; }

_search_app_uid()    { _search_cfg | jq -r --arg a "$1" '.apps[$a].uid // empty'; }
_search_app_prefix() { _search_cfg | jq -r --arg a "$1" '.apps[$a].prefix // empty'; }
_search_app_enabled() { [[ -n "$(_search_app_uid "$1")" ]]; }
_search_apps()       { _search_cfg | jq -r '(.apps // {}) | keys[]' 2>/dev/null || true; }

# The index prefix Cipi forces on an app. Not an operator choice: two apps that
# pick the same index name are not separated by the key pattern.
_search_prefix_for() { printf '%s-' "$1"; }

_search_require_installed() {
    _search_installed && return 0
    error "Meilisearch is not installed"
    echo -e "  Install it with: ${CYAN}cipi search install${NC}"
    return 1
}

_search_require_running() {
    _search_require_installed || return 1
    _search_running && return 0
    error "Meilisearch is installed but not running"
    echo -e "  Start it with:   ${CYAN}cipi service start meilisearch${NC}"
    echo -e "  Look at the log: ${CYAN}journalctl -u meilisearch -n 50${NC}"
    return 1
}

# ── HTTP ─────────────────────────────────────────────────────
#
# The master key never appears in an argument list: /proc/<pid>/cmdline is
# world-readable, and on a Cipi box every app user is a local user. curl reads
# the Authorization header from a stdin config file instead, and a request body
# goes through a 0600 temp file.
#
# Sets _SEARCH_HTTP_CODE and _SEARCH_HTTP_BODY in the caller's shell (command
# substitution would put them in a subshell and lose them).
_search_api() {
    local method="$1" path="$2" body="${3:-}"
    local key url out tmp rc=0
    key=$(_search_master_key)
    url="$(_search_url)${path}"
    _SEARCH_HTTP_CODE=""
    _SEARCH_HTTP_BODY=""

    local -a curl_args=(-sS -K - -X "$method" -w $'\n%{http_code}' --max-time 30)
    local cfg="header = \"Authorization: Bearer ${key}\""
    if [[ -n "$body" ]]; then
        tmp=$(mktemp); chmod 600 "$tmp"
        printf '%s' "$body" > "$tmp"
        curl_args+=(--data-binary "@${tmp}")
        cfg="${cfg}"$'\n'"header = \"Content-Type: application/json\""
    fi

    out=$(printf '%s\n' "$cfg" | curl "${curl_args[@]}" "$url" 2>/dev/null) || rc=$?
    if [[ -n "${tmp:-}" ]]; then rm -f "$tmp"; fi

    if [[ $rc -ne 0 && -z "$out" ]]; then
        _SEARCH_HTTP_CODE="000"
        return 1
    fi
    _SEARCH_HTTP_CODE="${out##*$'\n'}"
    _SEARCH_HTTP_BODY="${out%$'\n'*}"
    [[ "$_SEARCH_HTTP_CODE" =~ ^2 ]]
}

_search_api_fail() {
    local what="$1"
    local msg; msg=$(printf '%s' "${_SEARCH_HTTP_BODY:-}" | jq -r '.message // empty' 2>/dev/null || true)
    error "${what} failed (HTTP ${_SEARCH_HTTP_CODE:-000})"
    [[ -n "$msg" ]] && echo "  ${msg}"
    if [[ "${_SEARCH_HTTP_CODE:-}" == "000" ]]; then
        echo "  No answer on $(_search_url) — is meilisearch running?"
    fi
    return 1
}

# Wait for GET /health. Meilisearch opens the socket before the store is ready.
_search_wait_health() {
    local deadline=$(( SECONDS + ${1:-$SEARCH_HEALTH_TIMEOUT} )) st
    while (( SECONDS < deadline )); do
        st=$(curl -sS --max-time 3 "$(_search_url)/health" 2>/dev/null | jq -r '.status // empty' 2>/dev/null || true)
        [[ "$st" == "available" ]] && return 0
        systemctl is-active --quiet "$SEARCH_UNIT" 2>/dev/null || {
            # The unit died: no point waiting out the timeout.
            return 1
        }
        sleep 1
    done
    return 1
}

# ── .env helpers ─────────────────────────────────────────────
#
# Deliberately local rather than sourcing the 3700-line app.sh for four
# functions. Values written here are Cipi-generated (hex key, host URL,
# "<app>-") and need no quoting.

_search_env_get() {
    local file="$1" key="$2" line
    [[ -f "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "${key}="* ]] || continue
        line="${line#*=}"
        line="${line%\"}"; line="${line#\"}"
        printf '%s' "$line"
        return 0
    done < "$file"
    return 1
}

_search_env_set() {
    local file="$1" key="$2" val="$3"
    [[ -f "$file" ]] || return 0
    if grep -qE "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$file"
    else
        printf '%s=%s\n' "$key" "$val" >> "$file"
    fi
}

_search_env_del() {
    local file="$1"; shift
    [[ -f "$file" ]] || return 0
    local k
    for k in "$@"; do
        sed -i "/^${k}=/d" "$file" 2>/dev/null || true
    done
}

# Write the Scout block. Missing keys arrive together under one header instead
# of four stanzas each with its own blank line.
_search_env_block() {
    local file="$1"; shift
    [[ -f "$file" ]] || return 0
    local -a missing=()
    local pair key
    for pair in "$@"; do
        key="${pair%%=*}"
        if grep -qE "^${key}=" "$file" 2>/dev/null; then
            _search_env_set "$file" "$key" "${pair#*=}"
        else
            missing+=("$pair")
        fi
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    {
        printf '\n'
        grep -qxF '# Meilisearch (cipi search)' "$file" || printf '# Meilisearch (cipi search)\n'
        printf '%s\n' "${missing[@]}"
    } >> "$file"
    return 0
}

_search_app_env_file() {
    local app="$1"
    printf '/home/%s/shared/.env' "$app"
}

# ── install ──────────────────────────────────────────────────

_search_arch() {
    local a; a=$(dpkg --print-architecture 2>/dev/null || uname -m)
    case "$a" in
        amd64|x86_64)  echo "meilisearch-linux-amd64" ;;
        arm64|aarch64) echo "meilisearch-linux-aarch64" ;;
        *)             return 1 ;;
    esac
}

_search_latest_version() {
    local tag timeout="${1:-30}"
    tag=$(_cipi_run_timed "$timeout" curl -fsSL "https://api.github.com/repos/${SEARCH_REPO}/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null || true)
    [[ -z "$tag" ]] && return 1
    printf '%s' "${tag#v}"
}

# Version of the binary on disk ("meilisearch 1.53.2" → 1.53.2).
_search_bin_version() {
    [[ -x "$SEARCH_BIN" ]] || return 1
    "$SEARCH_BIN" --version 2>/dev/null | awk '{print $NF}' | tr -d '[:space:]'
}

_search_check_resources() {
    local force="${ARG_force:-}" ram disk fail=0
    ram=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    disk=$(df -Pk /var 2>/dev/null | awk 'NR==2 {print $4}')

    if [[ "${ram:-0}" -lt "$SEARCH_MIN_RAM_KB" ]]; then
        error "Meilisearch needs at least $((SEARCH_MIN_RAM_KB / 1024))MB free RAM (MemAvailable=$(( ${ram:-0} / 1024 ))MB)."
        echo "  It memory-maps its store, so it asks the kernel for far more than its RSS"
        echo "  suggests. On a box this tight the OOM killer may take MariaDB, not Meilisearch."
        fail=1
    elif [[ "${ram:-0}" -lt "$SEARCH_WARN_RAM_KB" ]]; then
        warn "Only $(( ${ram:-0} / 1024 ))MB free RAM. Meilisearch will run, but keep indexes small"
        warn "and watch 'cipi status' after the first scout:import."
    fi
    if [[ "${disk:-0}" -lt "$SEARCH_MIN_DISK_KB" ]]; then
        error "Meilisearch needs at least $((SEARCH_MIN_DISK_KB / 1024))MB free on /var (have $(( ${disk:-0} / 1024 ))MB)."
        fail=1
    fi

    [[ $fail -eq 0 ]] && return 0
    if [[ "$force" == "true" ]]; then
        warn "Continuing because --force"
        return 0
    fi
    echo "  Pass --force to install anyway, or leave search off: Scout's 'database'"
    echo "  driver needs no extra service at all."
    return 1
}

# Download a release binary and put it at $dest. Never overwrites the live
# binary until the download has been proved to run on this machine.
_search_fetch_binary() {
    local version="$1" dest="$2" asset url tmp
    asset=$(_search_arch) || { error "Unsupported architecture: $(uname -m) — Meilisearch ships amd64 and aarch64"; return 1; }
    url="https://github.com/${SEARCH_REPO}/releases/download/v${version}/${asset}"

    step "Downloading Meilisearch v${version} (${asset})..."
    tmp=$(mktemp)
    if ! _cipi_run_timed 300 curl -fsSL --retry 2 -o "$tmp" "$url"; then
        rm -f "$tmp"
        error "Download failed: ${url}"
        echo "  Check outbound HTTPS to github.com, and that v${version} exists."
        return 1
    fi
    chmod 0755 "$tmp"
    # Meilisearch publishes no checksum file next to the binaries, so the
    # verification available is behavioural: run it and read its version back.
    # Not as root — a fresh download from the internet gets the unprivileged
    # account it will run under anyway.
    local got
    if command -v runuser >/dev/null 2>&1 && id "$SEARCH_SYS_USER" &>/dev/null; then
        got=$(runuser -u "$SEARCH_SYS_USER" -- "$tmp" --version 2>/dev/null | awk '{print $NF}' | tr -d '[:space:]' || true)
    else
        got=$("$tmp" --version 2>/dev/null | awk '{print $NF}' | tr -d '[:space:]' || true)
    fi
    if [[ -z "$got" ]]; then
        rm -f "$tmp"
        error "The downloaded binary does not run on this machine"
        return 1
    fi
    if [[ "$got" != "$version" ]]; then
        warn "Release v${version} reports itself as ${got} — using it anyway"
    fi
    mv "$tmp" "$dest"
    chown root:root "$dest" 2>/dev/null || true
    chmod 0755 "$dest"
    return 0
}

_search_create_user() {
    if ! id "$SEARCH_SYS_USER" &>/dev/null; then
        useradd --system --home-dir "$SEARCH_HOME" --shell /usr/sbin/nologin "$SEARCH_SYS_USER" 2>/dev/null \
            || { error "Could not create the ${SEARCH_SYS_USER} system user"; return 1; }
    fi
    mkdir -p "${SEARCH_HOME}/dumps" "${SEARCH_HOME}/snapshots"
    chown -R "${SEARCH_SYS_USER}:${SEARCH_SYS_USER}" "$SEARCH_HOME"
    # 750: no app user has any business reading the raw store.
    chmod 750 "$SEARCH_HOME"
    return 0
}

_search_write_toml() {
    local port="$1"
    cat > "$SEARCH_TOML" <<EOF
# Managed by Cipi (cipi search). Secrets are NOT here: the master key is read
# from ${SEARCH_ENV_FILE} by systemd, so it never reaches this file or ps.
db_path      = "${SEARCH_HOME}/data.ms"
dump_dir     = "${SEARCH_HOME}/dumps"
snapshot_dir = "${SEARCH_HOME}/snapshots"
env          = "production"
http_addr    = "${SEARCH_HOST}:${port}"
no_analytics = true
EOF
    chown "root:${SEARCH_SYS_USER}" "$SEARCH_TOML" 2>/dev/null || true
    chmod 640 "$SEARCH_TOML"
}

# EnvironmentFile is read by systemd as root before the unit drops to the
# meilisearch user, so this can stay root-only.
_search_write_env_file() {
    local key="$1"
    _cipi_ensure_config_writable || { error "Cannot write ${SEARCH_ENV_FILE} (read-only ${CIPI_CONFIG})"; return 1; }
    cat > "$SEARCH_ENV_FILE" <<EOF
# Managed by Cipi (cipi search). Read by systemd, never by an app.
MEILI_MASTER_KEY=${key}
MEILI_NO_ANALYTICS=true
EOF
    chown root:root "$SEARCH_ENV_FILE" 2>/dev/null || true
    chmod 600 "$SEARCH_ENV_FILE"
}

_search_write_unit() {
    cat > "$SEARCH_UNIT_FILE" <<EOF
[Unit]
Description=Meilisearch (Cipi)
Documentation=https://cipi.sh/docs
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SEARCH_SYS_USER}
Group=${SEARCH_SYS_USER}
# The master key arrives here, not on the command line: /proc/<pid>/cmdline is
# world-readable and every Cipi app is a local user.
EnvironmentFile=${SEARCH_ENV_FILE}
ExecStart=${SEARCH_BIN} --config-file-path ${SEARCH_TOML}
Restart=on-failure
RestartSec=5
WorkingDirectory=${SEARCH_HOME}
# Indexing opens a lot of files at once; the stock 1024 is not enough.
LimitNOFILE=65535

NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${SEARCH_HOME}
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SEARCH_UNIT_FILE"
    systemctl daemon-reload
}

_search_install() {
    parse_args "$@"

    if _search_installed; then
        info "Meilisearch is already installed (v$(_search_bin_version 2>/dev/null || echo '?'))"
        echo -e "  Upgrade with: ${CYAN}cipi search upgrade${NC}"
        echo -e "  Enable an app: ${CYAN}cipi search enable <app>${NC}"
        return 0
    fi

    local b
    for b in curl jq openssl; do
        command -v "$b" >/dev/null 2>&1 || { error "${b} is required"; return 1; }
    done

    _search_check_resources || return 1

    local version="${ARG_version:-}"
    if [[ -z "$version" ]]; then
        step "Resolving the latest Meilisearch release..."
        version=$(_search_latest_version) || {
            error "Could not reach the GitHub release API"
            echo "  Pass an explicit version: cipi search install --version=1.53.2"
            return 1
        }
    fi
    version="${version#v}"

    local port="${ARG_port:-}"
    if [[ -z "$port" ]]; then
        port="$SEARCH_DEFAULT_PORT"
        if command -v ss &>/dev/null && ss -ltn 2>/dev/null | grep -qE ":${port}\\s"; then
            port=$(_allocate_localhost_port 7700 7799 'empty') || {
                error "No free port in 7700-7799"; return 1; }
            warn "Port ${SEARCH_DEFAULT_PORT} is taken — using ${port}"
        fi
    fi
    [[ "$port" =~ ^[0-9]{2,5}$ ]] || { error "Invalid port: ${port}"; return 1; }

    _search_create_user || return 1
    _search_fetch_binary "$version" "$SEARCH_BIN" || return 1

    local master; master=$(openssl rand -hex 32)
    _search_write_env_file "$master" || return 1
    _search_write_toml "$port"
    _search_write_unit

    # Record the master key before anything can fail: an instance that started
    # with a key Cipi did not save would be unmanageable — and unremovable.
    _search_cfg | jq \
        --arg k "$master" --arg v "$version" --arg h "$SEARCH_HOST" \
        --argjson p "$port" --arg t "$(date -Is)" \
        '. + {master_key:$k, version:$v, host:$h, port:$p, installed_at:$t, apps:(.apps // {})}' \
        | _search_cfg_save

    step "Starting meilisearch..."
    systemctl enable "$SEARCH_UNIT" >/dev/null 2>&1 || true
    if ! systemctl start "$SEARCH_UNIT" 2>/dev/null; then
        error "meilisearch failed to start"
        journalctl -u "$SEARCH_UNIT" -n 20 --no-pager 2>/dev/null | sed 's/^/  /' || true
        return 1
    fi

    if ! _search_wait_health; then
        error "meilisearch did not become healthy within ${SEARCH_HEALTH_TIMEOUT}s"
        journalctl -u "$SEARCH_UNIT" -n 20 --no-pager 2>/dev/null | sed 's/^/  /' || true
        return 1
    fi

    log_action "SEARCH: installed Meilisearch v${version} on ${SEARCH_HOST}:${port}"
    cipi_notify \
        "Cipi: Meilisearch installed on $(hostname)" \
        "Meilisearch was installed.\n\nServer: $(hostname)\nVersion: ${version}\nListen: ${SEARCH_HOST}:${port}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        search_install

    echo ""
    success "Meilisearch v${version} is running on ${SEARCH_HOST}:${port}"
    echo ""
    echo -e "  ${DIM}Next:${NC} ${CYAN}cipi search enable <app>${NC}"
    echo -e "  ${DIM}In the app:${NC} composer require laravel/scout meilisearch/meilisearch-php http-interop/http-factory-guzzle"
    echo -e "  ${DIM}Then:${NC}       php artisan scout:import \"App\\\\Models\\\\Post\""
    echo ""
}

# ── enable / disable ─────────────────────────────────────────

_search_create_key() {
    local app="$1" prefix="$2" body
    body=$(jq -n --arg n "cipi:${app}" --arg d "Cipi — Laravel Scout for app '${app}' (indexes ${prefix}*)" \
        --argjson a "$SEARCH_KEY_ACTIONS" --arg i "${prefix}*" \
        '{name:$n, description:$d, actions:$a, indexes:[$i], expiresAt:null}')
    _search_api POST /keys "$body" || { _search_api_fail "Creating the API key"; return 1; }
    printf '%s' "$_SEARCH_HTTP_BODY"
}

_search_delete_key() {
    local uid="$1"
    [[ -n "$uid" ]] || return 0
    if _search_api DELETE "/keys/${uid}" ""; then
        return 0
    fi
    # 404 means it is already gone — that is the desired end state.
    [[ "${_SEARCH_HTTP_CODE:-}" == "404" ]] && return 0
    return 1
}

_search_enable() {
    local app="${1:-}"; shift || true
    [[ -z "$app" ]] && { error "Usage: cipi search enable <app>"; exit 1; }
    parse_args "$@"
    app_exists "$app" || { error "App '${app}' not found"; exit 1; }
    [[ "$(app_get "$app" custom)" == "true" ]] && {
        error "Search is a Laravel Scout feature — custom apps have no .env"
        exit 1
    }
    _search_require_running || exit 1

    local envf; envf=$(_search_app_env_file "$app")
    [[ -f "$envf" ]] || { error ".env not found at ${envf}"; exit 1; }

    if _search_app_enabled "$app"; then
        info "Search is already enabled for '${app}' (prefix $(_search_app_prefix "$app"))"
        echo -e "  New key: ${CYAN}cipi search key rotate ${app}${NC}"
        return 0
    fi

    local prefix; prefix=$(_search_prefix_for "$app")

    # Cipi app names cannot contain '-', so "<app>-" can never be a prefix of
    # another app's prefix. Still assert it: the check is cheap and the failure
    # mode it guards against is one app reading another's documents.
    local other
    for other in $(_search_apps); do
        [[ "$other" == "$app" ]] && continue
        local op; op=$(_search_app_prefix "$other")
        if [[ "$prefix" == "$op"* || "$op" == "$prefix"* ]]; then
            error "Index prefix '${prefix}' overlaps app '${other}' ('${op}') — refusing"
            exit 1
        fi
    done

    step "Creating a scoped API key for '${app}' (${prefix}*)..."
    local created uid key
    created=$(_search_create_key "$app" "$prefix") || exit 1
    uid=$(printf '%s' "$created" | jq -r '.uid // empty')
    key=$(printf '%s' "$created" | jq -r '.key // empty')
    [[ -n "$uid" && -n "$key" ]] || { error "Meilisearch returned no key"; exit 1; }

    # Remember what the app was searching with, the way reverb enable records
    # the previous broadcaster: disable has to put something sane back.
    local prev; prev=$(_search_env_get "$envf" SCOUT_DRIVER 2>/dev/null || true)
    [[ "$prev" == "meilisearch" ]] && prev=""

    step "Writing Scout settings to ${envf}..."
    _search_env_block "$envf" \
        "SCOUT_DRIVER=meilisearch" \
        "SCOUT_PREFIX=${prefix}" \
        "MEILISEARCH_HOST=$(_search_url)" \
        "MEILISEARCH_KEY=${key}"
    chown "${app}:${app}" "$envf" 2>/dev/null || true
    chmod 640 "$envf" 2>/dev/null || true

    _search_cfg | jq --arg a "$app" --arg u "$uid" --arg p "$prefix" --arg d "$prev" --arg t "$(date -Is)" \
        '.apps = ((.apps // {}) + {($a): {uid:$u, prefix:$p, prev_scout_driver:$d, enabled_at:$t}})' \
        | _search_cfg_save
    app_set "$app" search "true"

    log_action "SEARCH: enabled for ${app} (prefix ${prefix}, key ${uid})"
    cipi_notify \
        "Cipi: search enabled for ${app} on $(hostname)" \
        "Meilisearch was enabled for an app.\n\nServer: $(hostname)\nApp: ${app}\nIndex prefix: ${prefix}\nKey uid: ${uid}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        search_enable

    echo ""
    success "Search enabled for '${app}'"
    echo ""
    printf "  %-16s ${CYAN}%s${NC}\n" "Host"   "$(_search_url)"
    printf "  %-16s ${CYAN}%s${NC}\n" "Prefix" "$prefix"
    printf "  %-16s ${CYAN}%s${NC}\n" "Key uid" "$uid"
    echo ""
    echo -e "  ${DIM}The key is scoped to ${prefix}* — an index without that prefix is refused.${NC}"
    echo -e "  ${DIM}Scout applies it through config('scout.prefix'); do not override SCOUT_PREFIX.${NC}"
    echo ""
    echo -e "  ${BOLD}In the app${NC}"
    echo -e "    composer require laravel/scout meilisearch/meilisearch-php http-interop/http-factory-guzzle"
    echo -e "    php artisan vendor:publish --provider=\"Laravel\\\\Scout\\\\ScoutServiceProvider\""
    echo -e "    php artisan scout:import \"App\\\\Models\\\\Post\""
    echo ""
    echo -e "  ${DIM}A cached config keeps the old values: run 'php artisan config:clear' (or redeploy).${NC}"
    echo ""
}

# Drop an app's key and, optionally, its indexes. Shared by `search disable`
# and `app delete` — which must never leave a live key behind for a user and a
# home that no longer exist.
_search_forget_app() {
    local app="$1" purge="${2:-false}" uid prefix
    uid=$(_search_app_uid "$app")
    prefix=$(_search_app_prefix "$app")
    [[ -n "$uid" || -n "$prefix" ]] || return 0

    if _search_running; then
        if [[ "$purge" == "true" && -n "$prefix" ]]; then
            local idx
            for idx in $(_search_list_indexes "$prefix"); do
                _search_api DELETE "/indexes/${idx}" "" >/dev/null 2>&1 || true
            done
        fi
        _search_delete_key "$uid" || warn "Could not delete the Meilisearch key ${uid} — remove it by hand"
    else
        warn "meilisearch is not running: key ${uid} was not deleted"
    fi

    _search_cfg | jq --arg a "$app" 'if .apps then .apps |= del(.[$a]) else . end' | _search_cfg_save
    return 0
}

# Index names under a prefix, via the master key.
_search_list_indexes() {
    local prefix="$1"
    _search_api GET "/indexes?limit=1000" "" >/dev/null 2>&1 || return 0
    printf '%s' "$_SEARCH_HTTP_BODY" \
        | jq -r --arg p "$prefix" '.results[]?.uid | select(startswith($p))' 2>/dev/null || true
}

_search_disable() {
    local app="${1:-}"; shift || true
    [[ -z "$app" ]] && { error "Usage: cipi search disable <app> [--purge-indexes]"; exit 1; }
    parse_args "$@"

    if ! _search_app_enabled "$app"; then
        info "Search is not enabled for '${app}'"
        return 0
    fi

    local purge="false"
    [[ "${ARG_purge_indexes:-}" == "true" ]] && purge="true"

    local prefix; prefix=$(_search_app_prefix "$app")
    local prev; prev=$(_search_cfg | jq -r --arg a "$app" '.apps[$a].prev_scout_driver // empty')
    # Scout's packaged default is algolia, which this app certainly cannot
    # reach. 'database' works against the DB Cipi already gave it.
    [[ -z "$prev" ]] && prev="database"

    local envf; envf=$(_search_app_env_file "$app")
    if [[ -f "$envf" ]]; then
        _search_env_set "$envf" SCOUT_DRIVER "$prev"
        _search_env_del "$envf" MEILISEARCH_KEY MEILISEARCH_HOST SCOUT_PREFIX
        chown "${app}:${app}" "$envf" 2>/dev/null || true
    fi

    _search_forget_app "$app" "$purge"
    app_exists "$app" && app_unset "$app" search

    log_action "SEARCH: disabled for ${app} (purge_indexes=${purge})"
    cipi_notify \
        "Cipi: search disabled for ${app} on $(hostname)" \
        "Meilisearch was disabled for an app.\n\nServer: $(hostname)\nApp: ${app}\nIndex prefix: ${prefix}\nIndexes dropped: ${purge}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        search_disable

    success "Search disabled for '${app}' (SCOUT_DRIVER=${prev})"
    [[ "$purge" != "true" ]] && echo -e "  ${DIM}Indexes ${prefix}* were kept. Drop them with --purge-indexes.${NC}"
    return 0
}

# ── keys ─────────────────────────────────────────────────────

_search_key_cmd() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        rotate) _search_key_rotate "$@" ;;
        show)   _search_key_show "$@" ;;
        *)
            error "Usage: cipi search key rotate <app>|--master   |   cipi search key show <app>"
            exit 1
            ;;
    esac
}

_search_key_show() {
    local app="${1:-}"
    [[ -z "$app" ]] && { error "Usage: cipi search key show <app>"; exit 1; }
    _search_app_enabled "$app" || { error "Search is not enabled for '${app}'"; exit 1; }
    _search_require_running || exit 1

    local uid; uid=$(_search_app_uid "$app")
    _search_api GET "/keys/${uid}" "" || { _search_api_fail "Reading the key"; exit 1; }
    printf '%s' "$_SEARCH_HTTP_BODY" | jq '{uid, name, indexes, actions, createdAt, key}'
}

# Rotate one app's key: the old one is destroyed, so anything still holding it
# (a cached config, a stale Octane worker) starts failing immediately.
_search_key_rotate() {
    parse_args "$@"
    if [[ "${ARG_master:-}" == "true" ]]; then
        _search_master_rotate
        return
    fi

    local app="${1:-}"
    [[ -z "$app" || "$app" == --* ]] && { error "Usage: cipi search key rotate <app>  |  cipi search key rotate --master"; exit 1; }
    _search_app_enabled "$app" || { error "Search is not enabled for '${app}'"; exit 1; }
    _search_require_running || exit 1

    local prefix old_uid
    prefix=$(_search_app_prefix "$app")
    old_uid=$(_search_app_uid "$app")

    step "Minting a new key for '${app}'..."
    local created uid key
    created=$(_search_create_key "$app" "$prefix") || exit 1
    uid=$(printf '%s' "$created" | jq -r '.uid // empty')
    key=$(printf '%s' "$created" | jq -r '.key // empty')
    [[ -n "$uid" && -n "$key" ]] || { error "Meilisearch returned no key"; exit 1; }

    local envf; envf=$(_search_app_env_file "$app")
    _search_env_set "$envf" MEILISEARCH_KEY "$key"
    chown "${app}:${app}" "$envf" 2>/dev/null || true

    _search_cfg | jq --arg a "$app" --arg u "$uid" '.apps[$a].uid = $u' | _search_cfg_save
    _search_delete_key "$old_uid" || warn "The old key ${old_uid} could not be deleted — remove it by hand"

    log_action "SEARCH: rotated key for ${app} (${old_uid} → ${uid})"
    cipi_notify \
        "Cipi: search key rotated for ${app} on $(hostname)" \
        "A Meilisearch API key was rotated.\n\nServer: $(hostname)\nApp: ${app}\nOld uid: ${old_uid}\nNew uid: ${uid}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        search_key_rotate

    success "New key written to ${envf}"
    echo -e "  ${DIM}The old key is gone. Run 'php artisan config:clear' (or redeploy) so the app picks this up.${NC}"
}

# Rotating the master key regenerates EVERY derived key: Meilisearch computes
# a key's value from its uid and the master key, so the uids survive but the
# values do not. Every enabled app's .env has to be rewritten in the same pass,
# or the whole server loses search at once.
_search_master_rotate() {
    _search_require_running || exit 1
    local apps; apps=$(_search_apps)

    echo ""
    warn "Rotating the master key invalidates every app key on this server."
    [[ -n "$apps" ]] && echo -e "  Affected apps: ${CYAN}$(printf '%s ' $apps)${NC}"
    echo -e "  ${DIM}Cipi rewrites each .env in the same run; searches fail until the app rereads it.${NC}"
    echo ""
    if [[ "${ARG_force:-}" != "true" ]]; then
        confirm "Rotate the Meilisearch master key?" || { info "Aborted"; return 0; }
    fi

    local new; new=$(openssl rand -hex 32)
    _search_write_env_file "$new" || return 1
    _search_cfg | jq --arg k "$new" '.master_key = $k' | _search_cfg_save

    step "Restarting meilisearch..."
    systemctl restart "$SEARCH_UNIT" 2>/dev/null || { error "Restart failed"; return 1; }
    _search_wait_health || { error "meilisearch did not come back healthy"; return 1; }

    local app uid key envf failed=0
    for app in $apps; do
        uid=$(_search_app_uid "$app")
        envf=$(_search_app_env_file "$app")
        if ! _search_api GET "/keys/${uid}" ""; then
            warn "Could not read the regenerated key for '${app}' (uid ${uid})"
            failed=$((failed + 1)); continue
        fi
        key=$(printf '%s' "$_SEARCH_HTTP_BODY" | jq -r '.key // empty')
        if [[ -z "$key" || ! -f "$envf" ]]; then
            warn "No key or no .env for '${app}' — fix it with: cipi search key rotate ${app}"
            failed=$((failed + 1)); continue
        fi
        _search_env_set "$envf" MEILISEARCH_KEY "$key"
        chown "${app}:${app}" "$envf" 2>/dev/null || true
        success "Rewrote MEILISEARCH_KEY for '${app}'"
    done

    log_action "SEARCH: master key rotated (${failed} app(s) not rewritten)"
    cipi_notify \
        "Cipi: Meilisearch master key rotated on $(hostname)" \
        "The Meilisearch master key was rotated and every app key regenerated.\n\nServer: $(hostname)\nApps rewritten: $(printf '%s ' $apps)\nFailures: ${failed}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        search_key_rotate

    echo ""
    if [[ $failed -eq 0 ]]; then
        success "Master key rotated; every app .env was rewritten"
    else
        warn "Master key rotated, but ${failed} app(s) still hold a dead key"
    fi
    echo -e "  ${DIM}Run 'php artisan config:clear' (or redeploy) on each app.${NC}"
}

# ── upgrade ──────────────────────────────────────────────────

# 1.12+ upgrades the store in place; the flag was --experimental-dumpless-
# upgrade before it settled as --upgrade-db. Ask the binary rather than
# guessing from a version number.
_search_upgrade_env_var() {
    local help; help=$("$SEARCH_BIN" --help 2>/dev/null || true)
    if grep -q -- '--upgrade-db' <<< "$help"; then
        echo "MEILI_UPGRADE_DB"
    elif grep -q -- '--experimental-dumpless-upgrade' <<< "$help"; then
        echo "MEILI_EXPERIMENTAL_DUMPLESS_UPGRADE"
    fi
}

_search_set_upgrade_dropin() {
    local var="$1"
    mkdir -p "$SEARCH_DROPIN_DIR"
    printf '[Service]\nEnvironment=%s=true\n' "$var" > "$SEARCH_UPGRADE_DROPIN"
    systemctl daemon-reload
}

_search_clear_upgrade_dropin() {
    [[ -f "$SEARCH_UPGRADE_DROPIN" ]] || return 0
    rm -f "$SEARCH_UPGRADE_DROPIN"
    rmdir "$SEARCH_DROPIN_DIR" 2>/dev/null || true
    systemctl daemon-reload
}

_search_upgrade() {
    parse_args "$@"
    _search_require_installed || exit 1

    local cur target
    cur=$(_search_bin_version || echo "")
    target="${ARG_version:-}"
    if [[ -z "$target" ]]; then
        step "Resolving the latest Meilisearch release..."
        target=$(_search_latest_version) || { error "Could not reach the GitHub release API"; exit 1; }
    fi
    target="${target#v}"

    if [[ "$cur" == "$target" && "${ARG_force:-}" != "true" ]]; then
        success "Already on v${cur}"
        return 0
    fi

    echo ""
    info "Meilisearch v${cur:-?} → v${target}"
    echo -e "  ${DIM}A Meilisearch store is readable only by the version that wrote it. Cipi tries the${NC}"
    echo -e "  ${DIM}in-place upgrade first; if the engine refuses, the binary is rolled back and you${NC}"
    echo -e "  ${DIM}choose whether to drop the indexes and re-run scout:import.${NC}"
    echo ""
    if [[ "${ARG_yes:-}" != "true" && "${ARG_force:-}" != "true" ]]; then
        confirm "Upgrade Meilisearch to v${target}?" || { info "Aborted"; return 0; }
    fi

    local backup="${SEARCH_BIN}.cipi-bak"
    cp -a "$SEARCH_BIN" "$backup" 2>/dev/null || true

    step "Stopping meilisearch..."
    systemctl stop "$SEARCH_UNIT" 2>/dev/null || true

    if ! _search_fetch_binary "$target" "$SEARCH_BIN"; then
        [[ -f "$backup" ]] && mv "$backup" "$SEARCH_BIN"
        systemctl start "$SEARCH_UNIT" 2>/dev/null || true
        error "Upgrade aborted — the old binary is back and meilisearch was restarted"
        return 1
    fi

    local var; var=$(_search_upgrade_env_var)
    if [[ -n "$var" ]]; then
        step "Starting v${target} with the in-place store upgrade (${var})..."
        _search_set_upgrade_dropin "$var"
    else
        warn "This build has no in-place upgrade flag — starting without it"
    fi

    local ok=false
    if systemctl start "$SEARCH_UNIT" 2>/dev/null && _search_wait_health 180; then
        ok=true
    fi
    _search_clear_upgrade_dropin

    if [[ "$ok" == "true" ]]; then
        # The upgrade flag must not stay on: it is a one-shot migration, not a
        # boot option. Restart once without it and prove it still comes up.
        systemctl restart "$SEARCH_UNIT" 2>/dev/null || true
        if ! _search_wait_health; then
            error "meilisearch came up during the upgrade but not on a normal restart"
            journalctl -u "$SEARCH_UNIT" -n 20 --no-pager 2>/dev/null | sed 's/^/  /' || true
            return 1
        fi
        rm -f "$backup"
        _search_cfg | jq --arg v "$target" '.version = $v' | _search_cfg_save
        log_action "SEARCH: upgraded Meilisearch ${cur:-?} → ${target}"
        cipi_notify \
            "Cipi: Meilisearch upgraded on $(hostname)" \
            "Meilisearch was upgraded.\n\nServer: $(hostname)\nFrom: ${cur:-?}\nTo: ${target}\nIndexes: kept\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
            search_upgrade
        success "Meilisearch is on v${target}, indexes intact"
        return 0
    fi

    # In-place upgrade refused. Show why before offering the destructive path.
    echo ""
    error "v${target} could not open the existing store"
    journalctl -u "$SEARCH_UNIT" -n 20 --no-pager 2>/dev/null | sed 's/^/  /' || true
    systemctl stop "$SEARCH_UNIT" 2>/dev/null || true

    echo ""
    echo -e "  A Scout index is derived data: dropping ${SEARCH_HOME}/data.ms and re-running"
    echo -e "  ${CYAN}php artisan scout:import${NC} rebuilds it from the database. Nothing else lives in there."
    echo ""
    local wipe="${ARG_reset_data:-}"
    if [[ "$wipe" != "true" ]]; then
        if confirm "Drop the search data and start v${target} clean?"; then
            wipe="true"
        fi
    fi

    if [[ "$wipe" != "true" ]]; then
        step "Rolling back to v${cur:-?}..."
        if [[ -f "$backup" ]]; then
            mv "$backup" "$SEARCH_BIN"
            systemctl start "$SEARCH_UNIT" 2>/dev/null || true
            _search_wait_health && success "Back on v${cur:-?} with the indexes intact" \
                || error "The rollback did not come up — check: journalctl -u meilisearch"
        else
            error "No backup binary to roll back to"
        fi
        return 1
    fi

    step "Dropping ${SEARCH_HOME}/data.ms..."
    rm -rf "${SEARCH_HOME}/data.ms"
    chown -R "${SEARCH_SYS_USER}:${SEARCH_SYS_USER}" "$SEARCH_HOME"
    systemctl start "$SEARCH_UNIT" 2>/dev/null || true
    if ! _search_wait_health; then
        error "meilisearch still will not start"
        journalctl -u "$SEARCH_UNIT" -n 20 --no-pager 2>/dev/null | sed 's/^/  /' || true
        return 1
    fi
    rm -f "$backup"

    # A wiped store has no keys. Every uid on record is dead: mint a new key per
    # app and rewrite its .env, or every enabled app answers 403 from now on.
    local app apps rebuilt=0
    apps=$(_search_apps)
    for app in $apps; do
        local prefix created uid key envf
        prefix=$(_search_app_prefix "$app")
        envf=$(_search_app_env_file "$app")
        created=$(_search_create_key "$app" "$prefix") || continue
        uid=$(printf '%s' "$created" | jq -r '.uid // empty')
        key=$(printf '%s' "$created" | jq -r '.key // empty')
        [[ -n "$uid" && -n "$key" && -f "$envf" ]] || continue
        _search_env_set "$envf" MEILISEARCH_KEY "$key"
        chown "${app}:${app}" "$envf" 2>/dev/null || true
        _search_cfg | jq --arg a "$app" --arg u "$uid" '.apps[$a].uid = $u' | _search_cfg_save
        rebuilt=$((rebuilt + 1))
    done

    _search_cfg | jq --arg v "$target" '.version = $v' | _search_cfg_save
    log_action "SEARCH: upgraded ${cur:-?} → ${target} with a data reset (${rebuilt} key(s) reissued)"
    cipi_notify \
        "Cipi: Meilisearch upgraded (indexes dropped) on $(hostname)" \
        "Meilisearch was upgraded and its store reset.\n\nServer: $(hostname)\nFrom: ${cur:-?}\nTo: ${target}\nIndexes: DROPPED — run scout:import\nKeys reissued: ${rebuilt}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        search_upgrade

    echo ""
    success "Meilisearch is on v${target} with an empty store (${rebuilt} key(s) reissued)"
    echo ""
    for app in $apps; do
        echo -e "  ${CYAN}cipi app artisan ${app} scout:import \"App\\\\Models\\\\...\"${NC}"
    done
    echo -e "  ${DIM}Run 'php artisan config:clear' first — the keys changed.${NC}"
    echo ""
}

# ── status / list ────────────────────────────────────────────

_search_list() {
    parse_args "$@"
    local apps; apps=$(_search_apps)

    if [[ "${ARG_json:-}" == "true" ]]; then
        _search_cfg | jq '{host, port, version, apps: ((.apps // {}) | map_values({uid, prefix, enabled_at}))}'
        return 0
    fi

    echo -e "\n${BOLD}Search-enabled apps${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ -z "$apps" ]]; then
        echo -e "  ${DIM}none — enable one with: cipi search enable <app>${NC}\n"
        return 0
    fi
    printf "  ${BOLD}%-18s %-16s %-8s %s${NC}\n" "APP" "PREFIX" "INDEXES" "KEY UID"
    local app prefix uid count
    for app in $apps; do
        prefix=$(_search_app_prefix "$app")
        uid=$(_search_app_uid "$app")
        count="-"
        if _search_running; then
            count=$(_search_list_indexes "$prefix" | grep -c . || true)
            [[ -z "$count" ]] && count=0
        fi
        printf "  %-18s %-16s %-8s ${DIM}%s${NC}\n" "$app" "$prefix" "$count" "$uid"
    done
    echo ""
}

_search_status() {
    parse_args "$@"

    local installed="false" running="false" version="" port health="unknown" dsize=""
    _search_installed && installed="true"
    _search_running && running="true"
    version=$(_search_bin_version 2>/dev/null || true)
    port=$(_search_port)
    if [[ "$running" == "true" ]]; then
        health=$(curl -sS --max-time 3 "$(_search_url)/health" 2>/dev/null | jq -r '.status // "unreachable"' 2>/dev/null || echo "unreachable")
    fi
    [[ -d "${SEARCH_HOME}/data.ms" ]] && dsize=$(du -sh "${SEARCH_HOME}/data.ms" 2>/dev/null | awk '{print $1}')

    if [[ "${ARG_json:-}" == "true" ]]; then
        jq -n --argjson i "$installed" --argjson r "$running" \
            --arg v "$version" --arg h "$SEARCH_HOST" --argjson p "${port:-0}" \
            --arg he "$health" --arg d "${dsize:-}" \
            --argjson apps "$(_search_cfg | jq '(.apps // {}) | map_values({uid, prefix, enabled_at})')" \
            '{installed:$i, running:$r, version:(if $v == "" then null else $v end),
              host:$h, port:$p, health:$he,
              data_size:(if $d == "" then null else $d end), apps:$apps}'
        return 0
    fi

    echo -e "\n${BOLD}Search (Meilisearch)${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ "$installed" != "true" ]]; then
        printf "  %-16s ${DIM}not installed${NC}\n" "Status"
        echo ""
        echo -e "  ${DIM}Opt-in. Nothing is installed until you run:${NC} ${CYAN}cipi search install${NC}"
        echo -e "  ${DIM}Not needed for small datasets: Scout's 'database' driver has no service.${NC}"
        echo ""
        return 0
    fi

    if [[ "$running" == "true" ]]; then
        printf "  %-16s ${GREEN}● running${NC}\n" "Status"
    else
        printf "  %-16s ${RED}● stopped${NC}\n" "Status"
    fi
    printf "  %-16s ${CYAN}%s${NC}\n" "Version" "${version:-?}"
    printf "  %-16s ${CYAN}%s${NC}\n" "Listen"  "$(_search_url)"
    printf "  %-16s ${CYAN}%s${NC}\n" "Health"  "$health"
    printf "  %-16s ${CYAN}%s${NC}\n" "Data"    "${SEARCH_HOME}/data.ms${dsize:+  (${dsize})}"
    printf "  %-16s ${CYAN}%s${NC}\n" "Master key" "vault + ${SEARCH_ENV_FILE} (root only)"

    local ram; ram=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    printf "  %-16s ${CYAN}%sMB${NC}\n" "Free RAM" "$(( ram / 1024 ))"

    # Only on request: status must not stall for 30s on a box with no egress.
    if [[ "${ARG_check:-}" == "true" ]]; then
        local latest; latest=$(_search_latest_version 10 2>/dev/null || true)
        if [[ -z "$latest" ]]; then
            printf "  %-16s ${DIM}could not reach github.com${NC}\n" "Update"
        elif [[ -n "$version" && "$latest" != "$version" ]]; then
            printf "  %-16s ${YELLOW}v%s available${NC} ${DIM}(cipi search upgrade)${NC}\n" "Update" "$latest"
        else
            printf "  %-16s ${GREEN}up to date${NC}\n" "Update"
        fi
    fi

    _search_list
    echo -e "  ${DIM}Indexes are derived data — they are not backed up, and 'cipi search upgrade'${NC}"
    echo -e "  ${DIM}may drop them. scout:import rebuilds from the database.${NC}"
    echo ""
}

# ── remove ───────────────────────────────────────────────────

_search_remove() {
    parse_args "$@"
    if ! _search_installed && [[ ! -f "$SEARCH_ENV_FILE" ]]; then
        info "Meilisearch is not installed"
        return 0
    fi

    local apps; apps=$(_search_apps)
    echo ""
    warn "This removes Meilisearch, its data and every scoped key."
    [[ -n "$apps" ]] && echo -e "  Apps that will lose search: ${CYAN}$(printf '%s ' $apps)${NC}"
    echo -e "  ${DIM}Their .env goes back to SCOUT_DRIVER=database and the Meilisearch keys are dropped.${NC}"
    echo -e "  ${DIM}Pass --keep-data to leave ${SEARCH_HOME} on disk.${NC}"
    echo ""
    if [[ "${ARG_force:-}" != "true" ]]; then
        confirm "Remove Meilisearch from this server?" || { info "Aborted"; return 0; }
    fi

    local app envf prev
    for app in $apps; do
        envf=$(_search_app_env_file "$app")
        prev=$(_search_cfg | jq -r --arg a "$app" '.apps[$a].prev_scout_driver // empty')
        [[ -z "$prev" ]] && prev="database"
        if [[ -f "$envf" ]]; then
            _search_env_set "$envf" SCOUT_DRIVER "$prev"
            _search_env_del "$envf" MEILISEARCH_KEY MEILISEARCH_HOST SCOUT_PREFIX
            chown "${app}:${app}" "$envf" 2>/dev/null || true
        fi
        app_exists "$app" && app_unset "$app" search
        success "Reverted '${app}' to SCOUT_DRIVER=${prev}"
    done

    step "Stopping and removing the unit..."
    systemctl stop "$SEARCH_UNIT" 2>/dev/null || true
    systemctl disable "$SEARCH_UNIT" >/dev/null 2>&1 || true
    rm -f "$SEARCH_UNIT_FILE" "$SEARCH_UPGRADE_DROPIN"
    rmdir "$SEARCH_DROPIN_DIR" 2>/dev/null || true
    systemctl daemon-reload
    systemctl reset-failed "$SEARCH_UNIT" 2>/dev/null || true

    step "Removing files..."
    rm -f "$SEARCH_BIN" "${SEARCH_BIN}.cipi-bak" "$SEARCH_TOML"
    if [[ "${ARG_keep_data:-}" == "true" ]]; then
        info "Kept ${SEARCH_HOME}"
    else
        rm -rf "$SEARCH_HOME"
    fi
    # The master key goes last: while it exists, the keys it derives are usable.
    rm -f "$SEARCH_ENV_FILE"
    rm -f "${CIPI_CONFIG}/${SEARCH_CFG}"
    id "$SEARCH_SYS_USER" &>/dev/null && userdel "$SEARCH_SYS_USER" 2>/dev/null || true

    log_action "SEARCH: removed Meilisearch"
    cipi_notify \
        "Cipi: Meilisearch removed from $(hostname)" \
        "Meilisearch was removed.\n\nServer: $(hostname)\nApps reverted: $(printf '%s ' $apps)\nData kept: ${ARG_keep_data:-false}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        search_remove

    echo ""
    success "Meilisearch removed"
    echo -e "  ${DIM}Run 'php artisan config:clear' on the reverted apps.${NC}"
    echo ""
}

# ── hooks for other commands ─────────────────────────────────

# Called from app_delete. The app's user, home and .env are about to go, so
# only the server-side leftovers matter: the key and the indexes.
search_cleanup_app() {
    local app="${1:-}"
    [[ -n "$app" ]] || return 0
    [[ -f "${CIPI_CONFIG}/${SEARCH_CFG}" ]] || return 0
    _search_app_enabled "$app" || return 0
    step "Search (Meilisearch)..."
    _search_forget_app "$app" true
    return 0
}
