#!/bin/bash
#############################################
# Cipi — Reset Server Passwords
#############################################

# ── ROOT SSH PASSWORD ────────────────────────────────────────

reset_root_password() {
    local new_pass
    new_pass=$(generate_password 40)
    echo "root:${new_pass}" | chpasswd

    # Update server.json
    local tmp
    tmp=$(mktemp)
    vault_read server.json | jq --arg p "$new_pass" '. + {root_password: $p}' > "$tmp"
    vault_write server.json < "$tmp"
    rm -f "$tmp"

    log_action "ROOT SSH PASSWORD RESET"

    cipi_notify \
        "Cipi root SSH password reset on $(hostname)" \
        "The root SSH password was regenerated.\n\nServer: $(hostname)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        reset_root_password

    echo ""
    echo -e "${GREEN}✓${NC} New root password: ${CYAN}${new_pass}${NC}"
    echo -e "${YELLOW}${BOLD}⚠ SAVE THIS PASSWORD — shown only once${NC}"
    echo ""
}

# ── DB ROOT PASSWORD ─────────────────────────────────────────

reset_db_root_password() {
    parse_args "$@"
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/db.sh"
    db_ensure_engine_state

    local engine="${ARG_engine:-}"
    if [[ -z "$engine" ]]; then
        engine=$(db_get_default_engine)
    fi
    engine=$(db_require_engine "$engine") || exit 1

    local new_pass
    new_pass=$(generate_password 40)

    case "$engine" in
        mariadb)
            local old_pass
            old_pass=$(db_get_root_password mariadb)
            "$(db_mysql_client)" -u root -p"${old_pass}" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${new_pass}'; FLUSH PRIVILEGES;" 2>/dev/null \
                || { error "Failed to change $(db_mysql_label) root password"; exit 1; }
            local tmp
            tmp=$(mktemp)
            vault_read server.json | jq --arg p "$new_pass" '.db_root_password = $p' > "$tmp"
            vault_write server.json < "$tmp"
            rm -f "$tmp"
            ;;
        pgsql)
            local old_pass
            old_pass=$(db_get_root_password pgsql)
            PGPASSWORD="$old_pass" psql -U postgres -h 127.0.0.1 -p 5432 -v ON_ERROR_STOP=1 \
                -c "ALTER USER postgres WITH PASSWORD '${new_pass}';" \
                || { error "Failed to change PostgreSQL password"; exit 1; }
            local tmp
            tmp=$(mktemp)
            vault_read server.json | jq --arg p "$new_pass" '
                .db_engines.pgsql.root_password = $p
                | del(.pgsql_root_password)
            ' > "$tmp"
            vault_write server.json < "$tmp"
            rm -f "$tmp"
            ;;
    esac

    log_action "DB ROOT PASSWORD RESET: $engine"
    cipi_notify \
        "Cipi $(db_engine_label "$engine") root password reset on $(hostname)" \
        "The $(db_engine_label "$engine") root password was regenerated.\n\nServer: $(hostname)\nEngine: ${engine}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        reset_db_password

    echo ""
    echo -e "${GREEN}✓${NC} New $(db_engine_label "$engine") root password: ${CYAN}${new_pass}${NC}"
    echo -e "${YELLOW}${BOLD}⚠ SAVE THIS PASSWORD — shown only once${NC}"
    echo ""
}

# ── VALKEY PASSWORD ──────────────────────────────────────────

# REDIS_PASSWORD in every app's shared/.env that still holds the previous
# password: since 5.7.2 `cipi app create` writes it there, so a reset has to
# follow or every app that moved cache, session or queue to Valkey breaks.
# A value someone set by hand (another password) is not touched. Prints the
# names of the apps it updated, one per line.
# Usage: _reset_valkey_env_sync <old_password> <new_password>
_reset_valkey_env_sync() {
    local old="$1" new="$2" app env old_re new_esc cur
    [[ -n "$old" && -n "$new" ]] || return 0
    [[ -f "${CIPI_CONFIG}/apps.json" ]] || return 0
    old_re=$(printf '%s' "$old" | sed 's/[][\.*^$|&/]/\\&/g')
    new_esc=$(printf '%s' "$new" | sed 's/[&|\\]/\\&/g')
    while IFS= read -r app; do
        [[ -n "$app" ]] || continue
        env="/home/${app}/shared/.env"
        [[ -f "$env" ]] || continue
        # Each app's .env is read and edited as that app's user (app_as in
        # common.sh): as root, a symlink there was another app's .env.
        cur=$(app_read "$app" "$env") || continue
        grep -qE "^REDIS_PASSWORD=[\"']?${old_re}[\"']?$" <<< "$cur" || continue
        app_sed "$app" "$env" "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=${new_esc}|" && echo "$app"
    done < <(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
    return 0
}

reset_valkey_password() {
    local new_pass old_pass
    new_pass=$(generate_password 40)
    old_pass=$(vault_read server.json 2>/dev/null | jq -r '.valkey_password // .redis_password // empty' 2>/dev/null)

    # Update valkey.conf
    if grep -q "^requirepass" /etc/valkey/valkey.conf; then
        sed -i "s/^requirepass.*/requirepass ${new_pass}/" /etc/valkey/valkey.conf
    else
        echo "requirepass ${new_pass}" >> /etc/valkey/valkey.conf
    fi

    systemctl restart valkey-server

    # Update server.json (write valkey_password; drop legacy redis_password)
    local tmp
    tmp=$(mktemp)
    vault_read server.json | jq --arg p "$new_pass" '. + {valkey_password: $p} | del(.redis_password)' > "$tmp"
    vault_write server.json < "$tmp"
    rm -f "$tmp"

    log_action "VALKEY PASSWORD RESET"

    cipi_notify \
        "Cipi Valkey password reset on $(hostname)" \
        "The Valkey password was regenerated.\n\nServer: $(hostname)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        reset_valkey_password

    local synced
    synced=$(_reset_valkey_env_sync "$old_pass" "$new_pass" | paste -sd' ' -)

    echo ""
    echo -e "${GREEN}✓${NC} New Valkey password: ${CYAN}${new_pass}${NC}"
    echo -e "${DIM}Valkey has been restarted.${NC}"
    if [[ -n "$synced" ]]; then
        echo -e "${GREEN}✓${NC} REDIS_PASSWORD updated in shared/.env of: ${synced}"
        echo -e "${DIM}An app with a cached config reads it after: cipi app artisan <app> optimize${NC}"
    fi
    echo -e "${YELLOW}Any other .env that holds the Valkey password has to be updated by hand.${NC}"
    echo -e "${YELLOW}${BOLD}⚠ SAVE THIS PASSWORD — shown only once${NC}"
    echo ""
}

# ── ROUTER ───────────────────────────────────────────────────

reset_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        root-password)  reset_root_password ;;
        db-password)    reset_db_root_password "$@" ;;
        valkey-password|redis-password) reset_valkey_password ;;
        *) error "Unknown: $sub"; echo "Use: root-password db-password valkey-password"; exit 1 ;;
    esac
}
