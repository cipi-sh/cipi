#!/bin/bash
#############################################
# Cipi — Server credentials
#############################################

# Port 3306 runs MariaDB or MySQL (db_mysql_* in common.sh); MariaDB for
# whatever sources this file without common.sh.
declare -f db_mysql_flavor >/dev/null 2>&1 || db_mysql_flavor() { echo mariadb; }
declare -f db_mysql_label  >/dev/null 2>&1 || db_mysql_label()  { echo MariaDB; }
declare -f db_mysql_client >/dev/null 2>&1 || db_mysql_client() { command -v mariadb >/dev/null 2>&1 && echo mariadb || echo mysql; }

# The passwords Cipi generates — root, the database roots, Valkey, the
# Meilisearch master key, the backup encryption key — live encrypted in
# /etc/cipi. The installer prints them once and waits until they are saved;
# this module prints the same card again (cipi credentials) and writes them
# as the plain CSV every password manager imports (cipi credentials export).
# setup.sh sources it before lib/common.sh is in its shell, so the card
# needs only vault_read, jq and the colour variables.

CRED_LABEL_WIDTH=16
# Field separator of the export rows: not whitespace, so an empty field
# (Meilisearch has no username) stays a field when `read` splits the row.
CRED_SEP=$'\x1f'

# One line of the card: "  Label:          value  note".
_cred_line() {
    local label="$1" value="$2" note="${3:-}"
    printf '  %-*s' "$CRED_LABEL_WIDTH" "${label}:"
    echo -e "${CYAN}${value}${NC}${note:+  ${DIM}${note}${NC}}"
}

_cred_title() { echo -e "  ${BOLD}$1${NC}"; }

# The address the outside reaches this server at: CRED_SERVER_IP when the
# caller already has it (the installer), server_public_ip (common.sh) when
# loaded, the same lookup otherwise.
_cred_server_ip() {
    local ip="${CRED_SERVER_IP:-}"
    if [[ -z "$ip" ]] && declare -f server_public_ip >/dev/null 2>&1; then
        ip=$(server_public_ip)
    elif [[ -z "$ip" ]]; then
        ip=$(curl -s --connect-timeout 3 --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]') || ip=""
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ip=""
    fi
    [[ -n "$ip" ]] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    printf '%s' "${ip:-<server-ip>}"
}

_cred_ssh_key_count() {
    local n
    n=$(grep -cE '^(ssh-|ecdsa-)' /home/cipi/.ssh/authorized_keys 2>/dev/null) || n="${n:-0}"
    printf '%s' "${n:-0}"
}

_cred_os() {
    local os
    os=$(lsb_release -ds 2>/dev/null) || os=""
    [[ -n "$os" ]] || os=$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release 2>/dev/null)
    printf '%s' "${os:-Ubuntu}"
}

# A ready connection URL. The databases listen on 127.0.0.1 only, so the
# MariaDB and PostgreSQL ones go through SSH as the cipi user (TablePlus's
# scheme, the one `cipi app create` prints; the key is the one on your
# machine, there is no SSH password). Valkey's is the plain redis:// URL,
# for a tunnel or the server itself.
_cred_url() {
    local engine="$1" ip="$2" user="$3" pass="$4"
    case "$engine" in
        mariadb) echo "$( [[ "$(db_mysql_flavor)" == "mysql" ]] && echo mysql || echo mariadb )+ssh://cipi@${ip}/${user}:${pass}@127.0.0.1:3306/" ;;
        pgsql)   echo "postgresql+ssh://cipi@${ip}/${user}:${pass}@127.0.0.1:5432/postgres" ;;
        valkey)  echo "redis://${user}:${pass}@127.0.0.1:6379" ;;
    esac
}

# One export row: title, url, username, password, notes joined by CRED_SEP.
_cred_row() {
    local IFS="$CRED_SEP"
    printf '%s\n' "$*"
}

# The records, one per line (see _cred_row). What exists on this server
# only: PostgreSQL, Meilisearch and the backup key appear once installed.
_cred_rows() {
    local cfg="${CIPI_CONFIG:-/etc/cipi}" sj host ip v vu
    sj=$(vault_read server.json 2>/dev/null) || sj="{}"
    [[ -n "$sj" ]] || sj="{}"
    host=$(hostname)
    ip=$(_cred_server_ip)

    v=$(jq -r '.root_password // empty' <<< "$sj")
    [[ -n "$v" ]] && _cred_row "Cipi ${host} — Root" "ssh://cipi@${ip}" "root" "$v" \
        "Root has no SSH login: ssh cipi@${ip} with your key, then su root. Reset: cipi reset root-password"

    v=$(jq -r '.db_root_password // empty' <<< "$sj")
    [[ -n "$v" ]] && _cred_row "Cipi ${host} — $(db_mysql_label) root" "$(_cred_url mariadb "$ip" root "$v")" "root" "$v" \
        "Listens on 127.0.0.1 only; the URL opens it through SSH as cipi (TablePlus, DBeaver). Reset: cipi reset db-password"

    v=$(jq -r '.db_engines.pgsql.root_password // .pgsql_root_password // empty' <<< "$sj")
    [[ -n "$v" ]] && _cred_row "Cipi ${host} — PostgreSQL" "$(_cred_url pgsql "$ip" postgres "$v")" "postgres" "$v" \
        "Listens on 127.0.0.1 only; the URL opens it through SSH as cipi (TablePlus, DBeaver). Reset: cipi reset db-password --engine=pgsql"

    v=$(jq -r '.valkey_password // .redis_password // empty' <<< "$sj")
    vu=$(jq -r '.valkey_user // .redis_user // "default"' <<< "$sj")
    [[ -n "$v" ]] && _cred_row "Cipi ${host} — Valkey" "$(_cred_url valkey "$ip" "$vu" "$v")" "$vu" "$v" \
        "Cache, sessions and queues of the apps (REDIS_PASSWORD in their .env); on the server only — tunnel: ssh -L 6379:127.0.0.1:6379 cipi@${ip}. Reset: cipi reset valkey-password"

    if [[ -f "${cfg}/search.json" ]]; then
        local sc mk mh mp
        sc=$(vault_read search.json 2>/dev/null) || sc="{}"
        [[ -n "$sc" ]] || sc="{}"
        mk=$(jq -r '.master_key // empty' <<< "$sc")
        mh=$(jq -r '.host // "127.0.0.1"' <<< "$sc")
        mp=$(jq -r '.port // 7700' <<< "$sc")
        [[ -n "$mk" ]] && _cred_row "Cipi ${host} — Meilisearch" "http://${mh}:${mp}" "" "$mk" \
            "Master key. On the server only — tunnel: ssh -L ${mp}:${mh}:${mp} cipi@${ip}, then http://localhost:${mp}. Each app gets a scoped key (cipi search enable <app>). Rotate: cipi search key rotate"
    fi

    if [[ -s "${cfg}/.backup_key" ]]; then
        v=$(cat "${cfg}/.backup_key")
        _cred_row "Cipi ${host} — Backup encryption key" "" "" "$v" \
            "AES-256 key of the encrypted backup archives (/etc/cipi/.backup_key): without it they cannot be read. cipi backup key show"
    fi
    return 0
}

# The card: a title per credential and the same "User:" / "Password:" rows
# under each one — one block, one password-manager entry.
credentials_card() {
    local cfg="${CIPI_CONFIG:-/etc/cipi}" sj host ip n v vu
    sj=$(vault_read server.json 2>/dev/null) || sj="{}"
    [[ -n "$sj" ]] || sj="{}"
    host=$(hostname)
    ip=$(_cred_server_ip)
    n=$(_cred_ssh_key_count)

    _cred_title "Server"
    _cred_line "IP" "$ip"
    _cred_line "Hostname" "$host"
    _cred_line "OS" "$(_cred_os)"
    echo ""

    _cred_title "SSH"
    _cred_line "User" "cipi" "sudo for every cipi command"
    _cred_line "Login" "ssh cipi@${ip}"
    _cred_line "Password" "none" "SSH key only — ${n} key$([[ "$n" == 1 ]] || echo s) on record (cipi ssh list)"
    echo ""

    v=$(jq -r '.root_password // empty' <<< "$sj")
    if [[ -n "$v" ]]; then
        _cred_title "Root"
        _cred_line "User" "root"
        _cred_line "Password" "$v"
        _cred_line "Login" "ssh cipi@${ip}, then: su root" "root has no SSH login"
        echo ""
    fi

    v=$(jq -r '.db_root_password // empty' <<< "$sj")
    if [[ -n "$v" ]]; then
        _cred_title "$(db_mysql_label)"
        _cred_line "User" "root"
        _cred_line "Password" "$v"
        _cred_line "Host" "127.0.0.1:3306" "local only — over SSH from outside"
        _cred_line "URL" "$(_cred_url mariadb "$ip" root "$v")" "TablePlus, DBeaver: SSH as cipi with your key"
        echo ""
    fi

    v=$(jq -r '.db_engines.pgsql.root_password // .pgsql_root_password // empty' <<< "$sj")
    if [[ -n "$v" ]]; then
        _cred_title "PostgreSQL"
        _cred_line "User" "postgres"
        _cred_line "Password" "$v"
        _cred_line "Host" "127.0.0.1:5432" "local only — over SSH from outside"
        _cred_line "URL" "$(_cred_url pgsql "$ip" postgres "$v")" "TablePlus, DBeaver: SSH as cipi with your key"
        echo ""
    fi

    v=$(jq -r '.valkey_password // .redis_password // empty' <<< "$sj")
    vu=$(jq -r '.valkey_user // .redis_user // "default"' <<< "$sj")
    if [[ -n "$v" ]]; then
        _cred_title "Valkey"
        _cred_line "User" "$vu"
        _cred_line "Password" "$v"
        _cred_line "Host" "127.0.0.1:6379" "the apps' REDIS_* settings"
        _cred_line "URL" "$(_cred_url valkey "$ip" "$vu" "$v")" "REDIS_URL; from outside: ssh -L 6379:127.0.0.1:6379 cipi@${ip}"
        echo ""
    fi

    if [[ -f "${cfg}/search.json" ]]; then
        local sc mk mh mp
        sc=$(vault_read search.json 2>/dev/null) || sc="{}"
        [[ -n "$sc" ]] || sc="{}"
        mk=$(jq -r '.master_key // empty' <<< "$sc")
        if [[ -n "$mk" ]]; then
            mh=$(jq -r '.host // "127.0.0.1"' <<< "$sc")
            mp=$(jq -r '.port // 7700' <<< "$sc")
            _cred_title "Meilisearch"
            _cred_line "Master key" "$mk"
            _cred_line "Host" "http://${mh}:${mp}" "apps use scoped keys (cipi search enable)"
            _cred_line "Tunnel" "ssh -L ${mp}:${mh}:${mp} cipi@${ip}" "then http://localhost:${mp} with the master key"
            echo ""
        fi
    fi

    if [[ -s "${cfg}/.backup_key" ]]; then
        _cred_title "Backup encryption key"
        _cred_line "Key" "$(cat "${cfg}/.backup_key")"
        _cred_line "File" "${cfg}/.backup_key" "encrypted archives cannot be read without it"
        echo ""
    fi
}

# cipi credentials [show]
credentials_show() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${BOLD}Server credentials${NC}  ${DIM}$(hostname)${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    credentials_card
    echo -e "  ${DIM}Password manager: cipi credentials export  (CSV: title,url,username,password,notes)${NC}"
    echo -e "  ${DIM}Regenerate: cipi reset root-password · cipi reset db-password [--engine=pgsql] · cipi reset valkey-password${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log_action "CREDENTIALS SHOWN"
    cipi_notify \
        "Cipi credentials shown on $(hostname)" \
        "The server credentials were printed with cipi credentials.\n\nServer: $(hostname)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        credentials_show
}

# A CSV field: quoted, inner quotes doubled (RFC 4180), no bare newline.
_cred_csv() {
    local s="${1//\"/\"\"}"
    printf '"%s"' "${s//$'\n'/ }"
}

_cred_csv_row() {
    local sep="" f
    for f in "$@"; do
        printf '%s' "$sep"; _cred_csv "$f"; sep=","
    done
    printf '\n'
}

# The rows (stdin) as CSV: title,url,username,password,notes — the plain
# layout 1Password, Bitwarden, Apple Passwords, Chrome, KeePassXC, Proton
# Pass and the rest import (most ask to confirm the column mapping once).
_cred_render() {
    local title url user pass notes
    echo "title,url,username,password,notes"
    while IFS="$CRED_SEP" read -r title url user pass notes; do
        [[ -n "$title" ]] || continue
        _cred_csv_row "$title" "$url" "$user" "$pass" "$notes"
    done
}

# cipi credentials export [--output=FILE]
# To stdout by default, so nothing is left on the server: run it over SSH
# from your own machine and redirect into a file there.
credentials_export() {
    unset ARG_output
    parse_args "$@"
    local out="${ARG_output:-}" rows
    rows=$(_cred_rows)
    [[ -n "$rows" ]] || { error "No credentials on record (server.json is empty)"; exit 1; }

    if [[ -n "$out" ]]; then
        if [[ -e "$out" ]]; then
            error "${out} exists — pick another name (nothing was written)"
            exit 1
        fi
        ( umask 077; _cred_render <<< "$rows" > "$out" ) || { error "Cannot write ${out}"; exit 1; }
        success "Written: ${out} (CSV, mode 600, $(( $(wc -l < "$out") - 1 )) entries)"
        echo -e "  ${YELLOW}Every password is in clear in that file.${NC} Import it, then delete it: ${CYAN}shred -u ${out}${NC}"
        log_action "CREDENTIALS EXPORTED: file=${out}"
    else
        _cred_render <<< "$rows"
        if [[ -t 1 ]]; then
            {
                echo ""
                echo -e "  ${DIM}Straight into a file on your own machine, nothing left on the server:${NC}"
                echo -e "  ${CYAN}ssh cipi@$(_cred_server_ip) sudo cipi credentials export > cipi-$(hostname).csv${NC}"
                echo ""
            } >&2
        fi
        log_action "CREDENTIALS EXPORTED"
    fi
    cipi_notify \
        "Cipi credentials exported on $(hostname)" \
        "The server credentials were exported with cipi credentials export.\n\nServer: $(hostname)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        credentials_show
}

credentials_command() {
    local sub="${1:-show}"
    shift || true
    case "$sub" in
        show|list|"") credentials_show ;;
        export)       credentials_export "$@" ;;
        --*)          credentials_export "$sub" "$@" ;;
        *)
            error "Unknown: $sub"
            echo "Use: cipi credentials [show] | export [--output=FILE]"
            exit 1 ;;
    esac
}
