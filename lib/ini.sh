#!/bin/bash
#############################################
# Cipi — PHP configuration (php.ini)
#
# PHP reads its settings from four places, and which one wins is rarely
# obvious. Cipi manages two of them and this command is the only thing you
# need to touch:
#
#   /etc/php/<ver>/{fpm,cli}/php.ini            stock package defaults, untouched
#   /etc/php/<ver>/{fpm,cli}/conf.d/99-cipi.ini Cipi's server-wide values  ← `cipi ini set`
#   /etc/php/<ver>/fpm/pool.d/<app>.conf        per-app overrides          ← `cipi ini set --app=`
#
# A server-wide change is written to both the FPM and the CLI SAPI, so a value
# set here applies to web requests, queue workers, artisan and cron alike —
# previously only FPM was configured and the CLI silently kept package
# defaults.
#############################################

ini_command() {
    local sub="${1:-list}"; shift||true
    case "$sub" in
        list|ls|show) _ini_list "$@" ;;
        get)          _ini_get "$@" ;;
        set)          _ini_set "$@" ;;
        unset|clear)  _ini_unset "$@" ;;
        reset)        _ini_reset "$@" ;;
        keys)         _ini_keys ;;
        *) error "Use: list get set unset reset keys"; exit 1 ;;
    esac
}

# ── Settable keys ────────────────────────────────────────────
#
# Fail-closed: only these keys can be written. The CLI is also reachable
# through the panel API, so an unrestricted php.ini editor would be an
# arbitrary-code-execution surface (auto_prepend_file, extension, …) rather
# than a convenience.
#
# key|type|description
_ini_key_catalog() {
    cat <<'EOF'
memory_limit|size|Memory a single request may allocate
upload_max_filesize|size|Largest accepted uploaded file
post_max_size|size|Largest POST body (must be >= upload_max_filesize)
max_execution_time|int|Seconds a request may run
max_input_time|int|Seconds spent parsing request input
max_input_vars|int|Maximum input variables per request
max_file_uploads|int|Maximum files in a single upload
default_socket_timeout|int|Default timeout for socket streams
date.timezone|tz|Default timezone
display_errors|flag|Print errors in the response (keep Off in production)
log_errors|flag|Write errors to the error log
output_buffering|int|Output buffer size in bytes (0 = off)
zlib.output_compression|flag|gzip output from PHP itself
session.gc_maxlifetime|int|Session lifetime in seconds
realpath_cache_size|size|Realpath cache size
realpath_cache_ttl|int|Realpath cache lifetime in seconds
expose_php|flag|Advertise PHP in the X-Powered-By header
opcache.enable|flag|Enable OPcache
opcache.enable_cli|flag|Enable OPcache for the CLI SAPI
opcache.memory_consumption|int|OPcache memory in megabytes
opcache.interned_strings_buffer|int|OPcache interned strings buffer in megabytes
opcache.max_accelerated_files|int|Maximum files OPcache keeps
opcache.validate_timestamps|flag|Re-check files for changes (Off in production)
opcache.revalidate_freq|int|Seconds between timestamp checks
opcache.jit|jit|JIT mode (off, tracing, function, or a 4-digit spec)
opcache.jit_buffer_size|size|JIT buffer size
EOF
}

# Keys refused on purpose, with the reason shown to the user.
_ini_key_denied() {
    cat <<'EOF'
open_basedir|Cipi sets this per app to confine it to its own home
disable_functions|Changing it would weaken the server-wide hardening
extension|Install extensions with apt, not through php.ini
zend_extension|Install extensions with apt, not through php.ini
auto_prepend_file|Would execute arbitrary code on every request
auto_append_file|Would execute arbitrary code on every request
include_path|Interacts with open_basedir; edit the app instead
error_log|Cipi points this at the app's own log directory
session.save_path|Cipi keeps sessions inside the app home
sys_temp_dir|Confined by open_basedir
upload_tmp_dir|Confined by open_basedir
EOF
}

_ini_key_type() { _ini_key_catalog | awk -F'|' -v k="$1" '$1 == k { print $2; exit }'; }
_ini_key_desc() { _ini_key_catalog | awk -F'|' -v k="$1" '$1 == k { print $3; exit }'; }
_ini_key_known() { _ini_key_catalog | cut -d'|' -f1 | grep -qx "$1"; }
_ini_key_deny_reason() { _ini_key_denied | awk -F'|' -v k="$1" '$1 == k { print $2; exit }'; }

_ini_keys() {
    echo -e "\n${BOLD}Settable PHP settings${NC}"
    local line k t d
    while IFS='|' read -r k t d; do
        [[ -n "$k" ]] || continue
        printf "  ${CYAN}%-34s${NC} ${DIM}%-5s${NC} %s\n" "$k" "$t" "$d"
    done < <(_ini_key_catalog)
    echo ""
    echo -e "${BOLD}Not settable here${NC} ${DIM}(managed by Cipi or unsafe to expose)${NC}"
    while IFS='|' read -r k d; do
        [[ -n "$k" ]] || continue
        printf "  ${DIM}%-34s %s${NC}\n" "$k" "$d"
    done < <(_ini_key_denied)
    echo ""
}

# ── Value validation ─────────────────────────────────────────

# "512M" → bytes. Prints -1 unchanged (PHP's "unlimited").
_ini_to_bytes() {
    local v="$1" num unit
    [[ "$v" == "-1" ]] && { echo "-1"; return 0; }
    [[ "$v" =~ ^([0-9]+)([KkMmGg]?)$ ]] || return 1
    num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
    case "$unit" in
        K|k) echo $(( num * 1024 )) ;;
        M|m) echo $(( num * 1024 * 1024 )) ;;
        G|g) echo $(( num * 1024 * 1024 * 1024 )) ;;
        *)   echo "$num" ;;
    esac
}

_ini_validate_value() {
    local key="$1" val="$2" type
    type=$(_ini_key_type "$key")
    case "$type" in
        size)
            if ! _ini_to_bytes "$val" >/dev/null; then
                error "Invalid value for ${key}: '${val}'"
                error "Expected a size such as 512K, 64M, 2G, a plain byte count, or -1 for unlimited."
                return 1
            fi
            ;;
        int)
            [[ "$val" =~ ^-?[0-9]+$ ]] || { error "Invalid value for ${key}: '${val}' (expected an integer)"; return 1; }
            ;;
        flag)
            case "$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')" in
                on|off|1|0|true|false|yes|no) ;;
                *) error "Invalid value for ${key}: '${val}' (expected On or Off)"; return 1 ;;
            esac
            ;;
        tz)
            [[ "$val" =~ ^[A-Za-z]+(/[A-Za-z0-9_+-]+)*$ ]] || { error "Invalid timezone: '${val}'"; return 1; }
            if command -v php >/dev/null 2>&1; then
                if ! php -r 'exit(in_array($argv[1], DateTimeZone::listIdentifiers(), true) ? 0 : 1);' "$val" 2>/dev/null; then
                    error "Unknown timezone: '${val}' (see: php -r 'print_r(DateTimeZone::listIdentifiers());')"
                    return 1
                fi
            fi
            ;;
        jit)
            [[ "$val" =~ ^(off|on|disable|tracing|function|[0-9]{4})$ ]] \
                || { error "Invalid opcache.jit value: '${val}' (off, tracing, function or a 4-digit spec)"; return 1; }
            ;;
        *)
            error "Unknown setting: ${key}"
            return 1
            ;;
    esac
    return 0
}

# Normalise a flag to PHP's On/Off spelling.
_ini_normalize_value() {
    local key="$1" val="$2"
    if [[ "$(_ini_key_type "$key")" == "flag" ]]; then
        case "$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')" in
            on|1|true|yes)  echo "On" ;;
            off|0|false|no) echo "Off" ;;
        esac
        return 0
    fi
    echo "$val"
}

# ── PHP versions ─────────────────────────────────────────────

_ini_installed_versions() {
    local v
    for v in 8.3 8.4 8.5; do
        [[ -d "/etc/php/${v}" ]] && echo "$v"
    done
}

_ini_global_file() { echo "/etc/php/${1}/${2}/conf.d/99-cipi.ini"; }

# ── Reading ──────────────────────────────────────────────────

_ini_read_global() {
    local ver="$1" sapi="$2" key="$3" file
    file=$(_ini_global_file "$ver" "$sapi")
    [[ -f "$file" ]] || return 1
    local esc; esc=$(printf '%s' "$key" | sed 's/[].[^$*\/]/\\&/g')
    grep -E "^[[:space:]]*${esc}[[:space:]]*=" "$file" 2>/dev/null | tail -1 \
        | sed 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//'
}

_ini_read_app() {
    local app="$1" key="$2"
    vault_read apps.json | jq -r --arg a "$app" --arg k "$key" '.[$a].ini[$k] // empty' 2>/dev/null
}

# Value PHP actually applies, and which layer it came from.
# Sets _INI_VALUE and _INI_SOURCE in the current shell — do not call via $(),
# which would run in a subshell and leave both unbound under `set -u`.
_ini_effective() {
    local key="$1" app="${2:-}" ver="$3" val=""
    _INI_SOURCE="unset"
    _INI_VALUE=""
    if [[ -n "$app" ]]; then
        val=$(_ini_read_app "$app" "$key")
        if [[ -n "$val" ]]; then
            _INI_SOURCE="app:${app}"; _INI_VALUE="$val"; return 0
        fi
        # Pool defaults Cipi always writes, whatever the global file says.
        case "$key" in
            memory_limit)
                val=$(_app_limit "$app" memory_limit "" 2>/dev/null || true)
                if [[ -n "$val" ]]; then
                    _INI_SOURCE="app-limit:${app}"; _INI_VALUE="$val"; return 0
                fi
                ;;
        esac
    fi
    val=$(_ini_read_global "$ver" fpm "$key" 2>/dev/null || true)
    if [[ -n "$val" ]]; then
        _INI_SOURCE="global"; _INI_VALUE="$val"; return 0
    fi
    if command -v "php${ver}" >/dev/null 2>&1; then
        val=$("php${ver}" -r 'echo ini_get($argv[1]);' "$key" 2>/dev/null || true)
        if [[ -n "$val" ]]; then
            _INI_SOURCE="php default"; _INI_VALUE="$val"; return 0
        fi
    fi
}

_ini_list() {
    parse_args "$@"
    local app="${ARG_app:-}" ver="${ARG_php:-}"
    if [[ -n "$app" ]]; then
        app_exists "$app" || { error "App '${app}' not found"; exit 1; }
        [[ -z "$ver" ]] && ver=$(app_get "$app" php)
    fi
    [[ -z "$ver" ]] && ver=$(_ini_installed_versions | tail -1)
    [[ -z "$ver" ]] && { error "No PHP installation found under /etc/php"; exit 1; }

    echo -e "\n${BOLD}PHP settings${NC} ${DIM}— PHP ${ver}${app:+, app '${app}'}${NC}"
    printf "  ${BOLD}%-34s %-14s %s${NC}\n" "SETTING" "VALUE" "SET BY"
    local k t d val
    while IFS='|' read -r k t d; do
        [[ -n "$k" ]] || continue
        _ini_effective "$k" "$app" "$ver"
        val="$_INI_VALUE"
        local col="$NC"
        [[ "$_INI_SOURCE" == app* ]] && col="$CYAN"
        [[ "$_INI_SOURCE" == "global" ]] && col="$GREEN"
        printf "  %-34s ${col}%-14s${NC} ${DIM}%s${NC}\n" "$k" "${val:-—}" "$_INI_SOURCE"
    done < <(_ini_key_catalog)
    echo ""
    if [[ -n "$app" ]]; then
        echo -e "  ${DIM}Change for this app only: ${CYAN}cipi ini set <key>=<value> --app=${app}${NC}"
    else
        echo -e "  ${DIM}Change server-wide (FPM + CLI): ${CYAN}cipi ini set <key>=<value>${NC}"
        echo -e "  ${DIM}Change for one app only:        ${CYAN}cipi ini set <key>=<value> --app=<app>${NC}"
    fi
    echo ""
}

_ini_get() {
    local pair="${1:-}"; shift||true
    [[ -z "$pair" ]] && { error "Usage: cipi ini get <key> [--app=<app>]"; exit 1; }
    parse_args "$@"
    local app="${ARG_app:-}" ver="${ARG_php:-}"
    if [[ -n "$app" ]]; then
        app_exists "$app" || { error "App '${app}' not found"; exit 1; }
        [[ -z "$ver" ]] && ver=$(app_get "$app" php)
    fi
    [[ -z "$ver" ]] && ver=$(_ini_installed_versions | tail -1)
    _ini_key_known "$pair" || { error "Unknown or non-settable key: ${pair}"; echo "Run: cipi ini keys"; exit 1; }
    _ini_effective "$pair" "$app" "$ver"
    echo -e "  ${CYAN}${pair}${NC} = ${_INI_VALUE:-—}  ${DIM}(${_INI_SOURCE})${NC}"
}

# ── Writing ──────────────────────────────────────────────────

# Idempotent "key = value" write into an ini file.
_ini_write_file() {
    local file="$1" key="$2" val="$3"
    mkdir -p "$(dirname "$file")"
    [[ -f "$file" ]] || printf '; Managed by Cipi — edit with: cipi ini set <key>=<value>\n' > "$file"
    local esc; esc=$(printf '%s' "$key" | sed 's/[].[^$*\/]/\\&/g')
    if grep -qE "^[[:space:]]*;?[[:space:]]*${esc}[[:space:]]*=" "$file" 2>/dev/null; then
        local tmp; tmp=$(mktemp)
        awk -v k="$key" -v v="$val" '
            {
                line = $0
                sub(/^[[:space:]]*;?[[:space:]]*/, "", line)
                split(line, parts, "=")
                gsub(/[[:space:]]+$/, "", parts[1])
                if (parts[1] == k && !done) { print k " = " v; done = 1; next }
                print
            }
        ' "$file" > "$tmp" && mv "$tmp" "$file"
    else
        printf '%s = %s\n' "$key" "$val" >> "$file"
    fi
    chmod 644 "$file" 2>/dev/null || true
}

_ini_remove_from_file() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    local tmp; tmp=$(mktemp)
    awk -v k="$key" '
        {
            line = $0
            sub(/^[[:space:]]*;?[[:space:]]*/, "", line)
            split(line, parts, "=")
            gsub(/[[:space:]]+$/, "", parts[1])
            if (parts[1] == k) next
            print
        }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# Warn when a change cannot take effect because a wider limit caps it.
_ini_related_warnings() {
    local key="$1" val="$2" app="${3:-}" ver="$4"
    local bytes; bytes=$(_ini_to_bytes "$val" 2>/dev/null || echo "")
    [[ -z "$bytes" || "$bytes" == "-1" ]] && return 0

    if [[ "$key" == "upload_max_filesize" ]]; then
        local nginx_max nginx_bytes
        nginx_max=$(grep -Eo 'client_max_body_size[[:space:]]+[0-9]+[KkMmGg]?' /etc/nginx/nginx.conf 2>/dev/null \
            | head -1 | awk '{print $2}')
        if [[ -n "$nginx_max" ]]; then
            nginx_bytes=$(_ini_to_bytes "$nginx_max" 2>/dev/null || echo 0)
            if [[ "$nginx_bytes" -gt 0 && "$bytes" -gt "$nginx_bytes" ]]; then
                warn "nginx caps request bodies at ${nginx_max} (client_max_body_size in /etc/nginx/nginx.conf)."
                warn "Uploads larger than that are rejected by nginx before PHP sees them."
            fi
        fi
    fi
}

# upload_max_filesize <= post_max_size <= memory_limit, or the setting the user
# asked for silently does nothing. Raising the companion values automatically
# is the whole point of a single command — but it is always reported.
_ini_cascade() {
    local key="$1" val="$2" app="${3:-}" ver="$4"
    local bytes; bytes=$(_ini_to_bytes "$val" 2>/dev/null || echo "")
    [[ -z "$bytes" || "$bytes" == "-1" ]] && return 0

    local companions=()
    case "$key" in
        upload_max_filesize) companions=(post_max_size memory_limit) ;;
        post_max_size)       companions=(memory_limit) ;;
        *) return 0 ;;
    esac

    local c cur cur_bytes
    for c in "${companions[@]}"; do
        _ini_effective "$c" "$app" "$ver"
        cur="$_INI_VALUE"
        [[ -z "$cur" ]] && continue
        cur_bytes=$(_ini_to_bytes "$cur" 2>/dev/null || echo "")
        [[ -z "$cur_bytes" ]] && continue
        [[ "$cur_bytes" == "-1" ]] && continue
        if [[ "$cur_bytes" -lt "$bytes" ]]; then
            warn "${c} was ${cur}, below ${key}=${val} — raising it to ${val} as well."
            _ini_apply "$c" "$val" "$app" "$ver" quiet
        fi
    done
}

# Write one key to the right layer. `mode=quiet` suppresses the success line
# (used by the cascade so the output stays readable).
_ini_apply() {
    local key="$1" val="$2" app="${3:-}" ver="$4" mode="${5:-}"

    if [[ -n "$app" ]]; then
        # Per-app override lives in apps.json and is rendered into the FPM pool,
        # so it survives a pool rewrite (app edit, limits change, migration).
        local cur; cur=$(vault_read apps.json | jq --arg a "$app" '.[$a].ini // {}')
        local next; next=$(echo "$cur" | jq --arg k "$key" --arg v "$val" '.[$k] = $v')
        app_set_json "$app" ini "$next"
        # app.sh may already be loaded (cipi yml apply sources it first);
        # sourcing it twice would re-run its readonly declarations.
        declare -f _create_fpm_pool >/dev/null 2>&1 || source "${CIPI_LIB}/app.sh"
        _create_fpm_pool "$app" "$ver"
        [[ "$mode" == "quiet" ]] || success "${key} = ${val}  (app '${app}')"
    else
        local v
        for v in $(_ini_installed_versions); do
            # Both SAPIs: a value set only for FPM leaves queue workers,
            # artisan and cron running on the package default.
            _ini_write_file "$(_ini_global_file "$v" fpm)" "$key" "$val"
            [[ -d "/etc/php/${v}/cli/conf.d" ]] && _ini_write_file "$(_ini_global_file "$v" cli)" "$key" "$val"
        done
        [[ "$mode" == "quiet" ]] || success "${key} = ${val}  (server-wide, FPM + CLI)"
    fi
}

_ini_set() {
    local pair="${1:-}"; shift||true
    [[ -z "$pair" ]] && { error "Usage: cipi ini set <key>=<value> [--app=<app>]"; exit 1; }
    parse_args "$@"

    local key val
    if [[ "$pair" == *=* ]]; then
        key="${pair%%=*}"; val="${pair#*=}"
    else
        key="$pair"; val="${1:-}"
        [[ -z "$val" ]] && { error "Usage: cipi ini set <key>=<value> [--app=<app>]"; exit 1; }
    fi
    key="${key# }"; key="${key% }"
    val="${val# }"; val="${val% }"

    local deny; deny=$(_ini_key_deny_reason "$key")
    if [[ -n "$deny" ]]; then
        error "'${key}' cannot be set with cipi ini — ${deny}."
        exit 1
    fi
    _ini_key_known "$key" || {
        error "Unknown or non-settable key: ${key}"
        echo "Settable keys: cipi ini keys"
        exit 1
    }
    _ini_validate_value "$key" "$val" || exit 1
    val=$(_ini_normalize_value "$key" "$val")

    local app="${ARG_app:-}" ver="${ARG_php:-}"
    if [[ -n "$app" ]]; then
        app_exists "$app" || { error "App '${app}' not found"; exit 1; }
        [[ "$(app_get "$app" octane)" == "frankenphp" ]] \
            && warn "'${app}' runs on Octane/FrankenPHP — FPM pool settings do not apply to it."
        [[ -z "$ver" ]] && ver=$(app_get "$app" php)
    else
        [[ -z "$ver" ]] && ver=$(_ini_installed_versions | tail -1)
    fi
    [[ -z "$ver" ]] && { error "No PHP installation found under /etc/php"; exit 1; }

    _ini_apply "$key" "$val" "$app" "$ver"
    _ini_cascade "$key" "$val" "$app" "$ver"
    _ini_related_warnings "$key" "$val" "$app" "$ver"
    _ini_reload "$app" "$ver"

    log_action "INI SET: ${key}=${val}${app:+ app=$app}"
    cipi_notify \
        "Cipi PHP setting changed: ${key} on $(hostname)" \
        "PHP configuration changed.\n\nServer: $(hostname)\nScope: ${app:-server-wide}\nSetting: ${key} = ${val}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        ini_set
}

_ini_unset() {
    local key="${1:-}"; shift||true
    [[ -z "$key" ]] && { error "Usage: cipi ini unset <key> [--app=<app>]"; exit 1; }
    parse_args "$@"
    _ini_key_known "$key" || { error "Unknown key: ${key}"; exit 1; }

    local app="${ARG_app:-}" ver="${ARG_php:-}"
    if [[ -n "$app" ]]; then
        app_exists "$app" || { error "App '${app}' not found"; exit 1; }
        [[ -z "$ver" ]] && ver=$(app_get "$app" php)
        local cur; cur=$(vault_read apps.json | jq --arg a "$app" '.[$a].ini // {}')
        app_set_json "$app" ini "$(echo "$cur" | jq --arg k "$key" 'del(.[$k])')"
        # app.sh may already be loaded (cipi yml apply sources it first);
        # sourcing it twice would re-run its readonly declarations.
        declare -f _create_fpm_pool >/dev/null 2>&1 || source "${CIPI_LIB}/app.sh"
        _create_fpm_pool "$app" "$ver"
        success "${key} removed for '${app}' — it now follows the server-wide value"
    else
        local v
        for v in $(_ini_installed_versions); do
            _ini_remove_from_file "$(_ini_global_file "$v" fpm)" "$key"
            _ini_remove_from_file "$(_ini_global_file "$v" cli)" "$key"
        done
        success "${key} removed server-wide — it now follows the PHP default"
    fi
    _ini_reload "$app" "$ver"
    log_action "INI UNSET: ${key}${app:+ app=$app}"
}

_ini_reset() {
    parse_args "$@"
    local app="${ARG_app:-}"
    if [[ -n "$app" ]]; then
        app_exists "$app" || { error "App '${app}' not found"; exit 1; }
        if [[ -t 0 ]]; then confirm "Drop all PHP overrides for '${app}'?" || { info "Cancelled"; return 0; }; fi
        local ver; ver=$(app_get "$app" php)
        app_set_json "$app" ini '{}'
        # app.sh may already be loaded (cipi yml apply sources it first);
        # sourcing it twice would re-run its readonly declarations.
        declare -f _create_fpm_pool >/dev/null 2>&1 || source "${CIPI_LIB}/app.sh"
        _create_fpm_pool "$app" "$ver"
        _ini_reload "$app" "$ver"
        success "PHP overrides cleared for '${app}'"
        log_action "INI RESET: app=$app"
        return 0
    fi

    if [[ -t 0 ]]; then confirm "Restore Cipi's default server-wide PHP settings?" || { info "Cancelled"; return 0; }; fi
    local v
    for v in $(_ini_installed_versions); do
        local body
        body='memory_limit = 256M
upload_max_filesize = 256M
post_max_size = 256M
max_execution_time = 300
max_input_time = 300
expose_php = Off'
        printf '; Managed by Cipi — edit with: cipi ini set <key>=<value>\n%s\n' "$body" \
            > "$(_ini_global_file "$v" fpm)"
        chmod 644 "$(_ini_global_file "$v" fpm)"
        if [[ -d "/etc/php/${v}/cli/conf.d" ]]; then
            printf '; Managed by Cipi — edit with: cipi ini set <key>=<value>\n%s\n' "$body" \
                > "$(_ini_global_file "$v" cli)"
            chmod 644 "$(_ini_global_file "$v" cli)"
        fi
    done
    _ini_reload "" ""
    success "Server-wide PHP settings restored to Cipi defaults"
    log_action "INI RESET: server-wide"
}

# FPM has to be restarted for conf.d/pool changes; the CLI picks them up on the
# next invocation.
_ini_reload() {
    local app="${1:-}" ver="${2:-}"
    local versions
    if [[ -n "$app" && -n "$ver" ]]; then versions="$ver"; else versions=$(_ini_installed_versions); fi
    local v
    for v in $versions; do
        systemctl is-active --quiet "php${v}-fpm" 2>/dev/null || continue
        if ! "php-fpm${v}" -t &>/dev/null && ! "/usr/sbin/php-fpm${v}" -t &>/dev/null; then
            warn "php-fpm${v} configuration test failed — not restarting. Check: php-fpm${v} -t"
            continue
        fi
        systemctl restart "php${v}-fpm" 2>/dev/null \
            && step "php${v}-fpm restarted" \
            || warn "Could not restart php${v}-fpm"
    done
}
