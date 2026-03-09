#!/bin/bash
#############################################
# Cipi — Common Functions
#############################################

source "${CIPI_LIB}/vault.sh"

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}✓${NC} $*"; }
step()    { echo -e "${CYAN}→${NC} $*"; }

log_action() {
    mkdir -p "${CIPI_LOG}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${CIPI_LOG}/cipi.log"
}

log_event() {
    mkdir -p "${CIPI_LOG}"
    local ip; ip=$(_get_client_ip 2>/dev/null || echo "local")
    local key; key=$(_get_session_key_name 2>/dev/null || echo "n/a")
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${ip}] [key:${key}] $*" >> "${CIPI_LOG}/events.log"
}

_get_client_ip() {
    if [[ -n "${SSH_CLIENT:-}" ]]; then
        echo "${SSH_CLIENT%% *}"
    elif [[ -n "${SSH_CONNECTION:-}" ]]; then
        echo "${SSH_CONNECTION%% *}"
    else
        echo "local"
    fi
}

_get_session_key_name() {
    local fp=""

    # Method 1: SSH_USER_AUTH (requires ExposeAuthInfo=yes + env_keep in sudoers)
    local auth_file="${SSH_USER_AUTH:-}"
    if [[ -n "$auth_file" && -f "$auth_file" ]]; then
        fp=$(awk '/^publickey / {print $3; exit}' "$auth_file" 2>/dev/null)
    fi

    # Method 2: auth.log fallback
    if [[ -z "$fp" && -f /var/log/auth.log ]]; then
        local client_ip; client_ip=$(_get_client_ip)
        local login_user="${SUDO_USER:-cipi}"
        local log_line
        log_line=$(grep "Accepted publickey for ${login_user} from ${client_ip}" /var/log/auth.log 2>/dev/null | tail -1)
        [[ -n "$log_line" ]] && fp=$(echo "$log_line" | grep -o 'SHA256:[^ ]*')
    fi

    [[ -z "$fp" ]] && { echo "n/a"; return; }

    local ak="/home/cipi/.ssh/authorized_keys"
    [[ -f "$ak" ]] || { echo "$fp"; return; }

    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        local line_fp
        line_fp=$(echo "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
        if [[ "$line_fp" == "$fp" ]]; then
            local comment
            comment=$(echo "$line" | awk '{$1=$2=""; print}' | xargs)
            [[ -n "$comment" ]] && { echo "$comment"; return; }
        fi
    done < "$ak"
    echo "$fp"
}

generate_password() { openssl rand -base64 64 | tr -dc 'a-zA-Z0-9' | head -c "${1:-40}"; }
generate_token()    { openssl rand -hex 32; }
generate_app_key()  { echo "base64:$(openssl rand -base64 32)"; }

validate_username() {
    local n="$1"
    [[ ! "$n" =~ ^[a-z][a-z0-9]{2,31}$ ]] && return 1
    local bad=("root" "admin" "www" "nginx" "mysql" "mariadb" "redis" "git" "deploy" "cipi" "ubuntu" "debian" "supervisor" "nobody" "postfix" "sshd" "clamav" "daemon" "bin" "sys")
    for b in "${bad[@]}"; do [[ "$n" == "$b" ]] && return 1; done
    return 0
}

validate_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]
}

validate_php_version() {
    case "$1" in 7.4|8.0|8.1|8.2|8.3|8.4|8.5) return 0 ;; *) return 1 ;; esac
}

php_is_installed() { dpkg -l "php${1}-fpm" &>/dev/null 2>&1; }

app_exists() {
    [[ -f "${CIPI_CONFIG}/apps.json" ]] && vault_read apps.json | jq -e --arg a "$1" '.[$a]' &>/dev/null
}

# Check if domain is used by another app (domain or alias). Exclude app name when editing.
# Returns 0 if in use, 1 if free. If in use, sets DOMAIN_USED_BY_APP for error message.
domain_is_used_by_other_app() {
    local dom="$1" exclude_app="${2:-}"
    DOMAIN_USED_BY_APP=""
    [[ ! -f "${CIPI_CONFIG}/apps.json" ]] && return 1
    DOMAIN_USED_BY_APP=$(vault_read apps.json | jq -r --arg d "$dom" --arg e "$exclude_app" '
        to_entries[] | select(.key != $e) |
        select(.value.domain == $d or ((.value.aliases // []) | index($d) != null)) |
        .key
    ' 2>/dev/null | head -1)
    [[ -n "$DOMAIN_USED_BY_APP" ]]
}

app_get() { vault_read apps.json | jq -r --arg a "$1" --arg k "$2" '.[$a][$k] // empty'; }

# Generate apps-public.json: a plaintext projection of apps.json containing
# only non-sensitive fields (domain, aliases, php, branch, repository, user,
# created_at). The encrypted apps.json keeps webhook tokens and git IDs safe.
_update_apps_public() {
    [[ -f "${CIPI_CONFIG}/apps.json" ]] || return 0
    vault_read apps.json | jq '
        with_entries(.value |= {domain, aliases, php, branch, repository, user, created_at})
    ' > "${CIPI_CONFIG}/apps-public.json"
    chmod 640 "${CIPI_CONFIG}/apps-public.json"
    chgrp cipi-api "${CIPI_CONFIG}/apps-public.json" 2>/dev/null || true
}

# When Cipi API is configured, ensure www-data can read apps-public.json via
# the cipi-api group. The encrypted apps.json stays root-only (600).
ensure_apps_json_api_access() {
    [[ -f "${CIPI_CONFIG}/api.json" ]] || return 0
    [[ -f "${CIPI_CONFIG}/apps.json" ]] || return 0
    if ! getent group cipi-api &>/dev/null; then
        groupadd cipi-api 2>/dev/null || true
    fi
    if ! id -nG www-data 2>/dev/null | grep -qw cipi-api; then
        usermod -aG cipi-api www-data 2>/dev/null || true
    fi
    chgrp cipi-api "${CIPI_CONFIG}" 2>/dev/null || true
    chmod 750 "${CIPI_CONFIG}" 2>/dev/null || true
    _update_apps_public
}

app_set() {
    vault_read apps.json | jq --arg a "$1" --arg k "$2" --arg v "$3" '.[$a][$k] = $v' | vault_write apps.json
    ensure_apps_json_api_access
}

app_save() {
    local json
    json=$(vault_read apps.json) || json="{}"
    local result
    if ! result=$(echo "$json" | jq --arg a "$1" --argjson d "$2" '.[$a] = $d' 2>/dev/null); then
        error "Failed to save app config (invalid JSON?)"; return 1
    fi
    echo "$result" | vault_write apps.json
    ensure_apps_json_api_access
}

app_remove() {
    vault_read apps.json | jq --arg a "$1" 'del(.[$a])' | vault_write apps.json
    ensure_apps_json_api_access
}

get_db_root_password() { vault_read server.json | jq -r '.db_root_password'; }

confirm() {
    echo -e -n "${YELLOW}${1:-Are you sure?} [y/N]: ${NC}"; read -r r; [[ "$r" =~ ^[Yy]$ ]]
}

read_input() {
    local prompt="$1" default="${2:-}" var="$3"
    if [[ -n "$default" ]]; then echo -e -n "${CYAN}${prompt}${NC} [${default}]: "
    else echo -e -n "${CYAN}${prompt}${NC}: "; fi
    read -r input; printf -v "$var" '%s' "${input:-$default}"
}

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --*=*) local k="${arg%%=*}"; k="${k#--}"; printf -v "ARG_${k//-/_}" '%s' "${arg#*=}" ;;
            --*)   local k="${arg#--}"; printf -v "ARG_${k//-/_}" '%s' "true" ;;
        esac
    done
}

reload_nginx() {
    if ! nginx -t 2>&1; then
        error "nginx config test failed. Fix config and run: nginx -t"
        return 1
    fi
    systemctl reload nginx || { error "systemctl reload nginx failed"; return 1; }
}

reload_php_fpm() {
    systemctl restart "php${1}-fpm" || { error "Failed to restart php${1}-fpm"; return 1; }
}

reload_supervisor() {
    supervisorctl reread 2>&1 || { error "supervisorctl reread failed"; return 1; }
    supervisorctl update 2>&1 || warn "Supervisor update had issues (worker may start after first deploy)"
}

_create_supervisor_worker() {
    local app="$1" v="$2" queue="${3:-default}" procs="${4:-1}" tries="${5:-3}" timeout="${6:-3600}"
    cat >> "/etc/supervisor/conf.d/${app}.conf" <<EOF
[program:${app}-worker-${queue}]
process_name=%(program_name)s_%(process_num)02d
command=/usr/bin/php${v} /home/${app}/current/artisan queue:work database --sleep=3 --tries=${tries} --max-time=${timeout} --queue=${queue}
autostart=true
autorestart=unexpected
startretries=5
startsecs=3
stopasgroup=true
killasgroup=true
user=${app}
numprocs=${procs}
redirect_stderr=true
stdout_logfile=/home/${app}/logs/worker-${queue}.log
stdout_logfile_maxbytes=10MB
stopwaitsecs=${timeout}
EOF
}

# Init config on source
mkdir -p "${CIPI_CONFIG}" "${CIPI_LOG}"
chmod 700 "${CIPI_CONFIG}"
vault_init
for f in apps.json databases.json; do
    if [[ ! -f "${CIPI_CONFIG}/$f" ]]; then
        echo "{}" | vault_write "$f"
    fi
done
ensure_apps_json_api_access

# Email notifications (optional) — cipi_notify "Subject" "Body"
[[ -f "${CIPI_LIB}/smtp.sh" ]] && source "${CIPI_LIB}/smtp.sh"
