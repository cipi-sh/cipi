#!/bin/bash
#############################################
# Cipi — Common Functions
#############################################

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}✓${NC} $*"; }
step()    { echo -e "${CYAN}→${NC} $*"; }

log_action() {
    mkdir -p "${CIPI_LOG}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${CIPI_LOG}/cipi.log"
}

generate_password() { openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "${1:-32}"; }
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
    [[ -f "${CIPI_CONFIG}/apps.json" ]] && jq -e --arg a "$1" '.[$a]' "${CIPI_CONFIG}/apps.json" &>/dev/null
}

app_get() { jq -r --arg a "$1" --arg k "$2" '.[$a][$k] // empty' "${CIPI_CONFIG}/apps.json"; }

app_set() {
    local tmp; tmp=$(mktemp)
    jq --arg a "$1" --arg k "$2" --arg v "$3" '.[$a][$k] = $v' "${CIPI_CONFIG}/apps.json" > "$tmp"
    mv "$tmp" "${CIPI_CONFIG}/apps.json"; chmod 600 "${CIPI_CONFIG}/apps.json"
}

app_save() {
    [[ -f "${CIPI_CONFIG}/apps.json" ]] || echo "{}" > "${CIPI_CONFIG}/apps.json"
    local tmp; tmp=$(mktemp)
    if ! jq --arg a "$1" --argjson d "$2" '.[$a] = $d' "${CIPI_CONFIG}/apps.json" > "$tmp" 2>/dev/null; then
        error "Failed to save app config (invalid JSON?)"; rm -f "$tmp"; return 1
    fi
    mv "$tmp" "${CIPI_CONFIG}/apps.json"; chmod 600 "${CIPI_CONFIG}/apps.json"
}

app_remove() {
    local tmp; tmp=$(mktemp)
    jq --arg a "$1" 'del(.[$a])' "${CIPI_CONFIG}/apps.json" > "$tmp"
    mv "$tmp" "${CIPI_CONFIG}/apps.json"; chmod 600 "${CIPI_CONFIG}/apps.json"
}

get_db_root_password() { jq -r '.db_root_password' "${CIPI_CONFIG}/server.json"; }

confirm() {
    echo -e -n "${YELLOW}${1:-Are you sure?} [y/N]: ${NC}"; read -r r; [[ "$r" =~ ^[Yy]$ ]]
}

read_input() {
    local prompt="$1" default="${2:-}" var="$3"
    if [[ -n "$default" ]]; then echo -e -n "${CYAN}${prompt}${NC} [${default}]: "
    else echo -e -n "${CYAN}${prompt}${NC}: "; fi
    read -r input; eval "$var=\"${input:-$default}\""
}

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --*=*) local k="${arg%%=*}"; k="${k#--}"; eval "ARG_${k//-/_}=\"${arg#*=}\"" ;;
            --*)   local k="${arg#--}"; eval "ARG_${k//-/_}=true" ;;
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
autorestart=true
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
for f in apps.json databases.json; do
    if [[ ! -f "${CIPI_CONFIG}/$f" ]]; then
        echo "{}" > "${CIPI_CONFIG}/$f" && chmod 600 "${CIPI_CONFIG}/$f"
    fi
done
