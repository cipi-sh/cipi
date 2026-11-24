#!/bin/bash
#############################################
# Cipi — Sync (Export / Import / List)
#############################################

# Set by _sync_export when called from _sync_push (avoids glob lookup)
_SYNC_LAST_ARCHIVE=""

sync_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        export) _sync_export "$@" ;;
        import) _sync_import "$@" ;;
        list)   _sync_list "$@" ;;
        push)   _sync_push "$@" ;;
        trust)  _sync_trust "$@" ;;
        pubkey) _sync_pubkey ;;
        *) error "Use: export import list push trust pubkey"; exit 1 ;;
    esac
}

# ── EXPORT ────────────────────────────────────────────────────

# One file of an app's home into the export, read as the app's user. A file
# that is not there, or that its own user cannot read, is left out. The copy
# gets the mode `cp` gave it — the file's own, under umask 022 — because
# `cipi sync import` copies it on as it finds it.
_sync_export_copy() {   # <app> <file> <destination>
    local m=""
    [[ -f "$2" ]] || return 0
    ( umask 077; app_read "$1" "$2" > "$3" ) 2>/dev/null || { rm -f "$3"; return 0; }
    m=$(app_as "$1" stat -L -c '%a' -- "$2" 2>/dev/null < /dev/null || true)
    if [[ "$m" =~ ^[0-7]{3,4}$ ]]; then
        chmod "$(printf '%o' $(( 8#$m & 8#755 )))" "$3" 2>/dev/null || true
    fi
    return 0
}
# shared/storage as a tar.gz, made by the app's user. A second try after
# handing the tree back, for files root left there (see _app_reown).
_sync_export_storage() {   # <app> <archive>
    local app="$1" out="$2"
    app_as "$app" tar -czf - -C "/home/${app}/shared" storage/ > "$out" 2>/dev/null < /dev/null && return 0
    _app_reown "$app" "/home/${app}/shared/storage" || return 1
    app_as "$app" tar -czf - -C "/home/${app}/shared" storage/ > "$out" 2>/dev/null < /dev/null
}
# shared/storage back from a tar.gz, unpacked by the app's user with the
# modes it was packed with (-p: what tar does for root on its own).
_sync_import_storage() {   # <app> <archive>
    local app="$1" in="$2" dest="/home/${1}/shared/"
    app_as "$app" tar -xzpf - -C "$dest" < "$in" 2>/dev/null && return 0
    _app_reown "$app" "/home/${app}/shared/storage" || return 1
    app_as "$app" tar -xzpf - -C "$dest" < "$in" 2>/dev/null
}

_sync_export() {
    parse_args "$@"

    local with_db="${ARG_with_db:-false}"
    local with_storage="${ARG_with_storage:-false}"
    local output="${ARG_output:-}"
    local passphrase="${ARG_passphrase:-}"
    local internal_push="${ARG_internal_push:-false}"
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    local hostname; hostname=$(hostname 2>/dev/null || echo "unknown")
    local archive="${output:-/tmp/cipi-sync-${hostname}-${ts}.tar.gz}"

    # Collect app names: positional args (excluding --flags)
    local -a apps=()
    for arg in "$@"; do
        [[ "$arg" == --* ]] && continue
        apps+=("$arg")
    done

    # If no apps specified, export all
    if [[ ${#apps[@]} -eq 0 ]]; then
        local _aj; _aj=$(vault_read apps.json)
        if [[ $(echo "$_aj" | jq 'length') -eq 0 ]]; then
            error "No apps found"; exit 1
        fi
        mapfile -t apps < <(echo "$_aj" | jq -r 'keys[]')
    fi

    # Validate all requested apps exist
    for a in "${apps[@]}"; do
        app_exists "$a" || { error "App '$a' not found"; exit 1; }
    done

    info "Exporting ${#apps[@]} app(s): ${apps[*]}"
    [[ "$with_db" == "true" ]] && info "Including database dumps"
    [[ "$with_storage" == "true" ]] && info "Including shared storage"
    echo ""

    # Staged in a private directory. It was /tmp/cipi-sync-<time>, world-readable,
    # for as long as the export ran: every app's .env, the decrypted apps.json,
    # databases.json, smtp.json and the database dumps, open to any local user
    # (5.9.0). The archive keeps its top-level name, cipi-sync-<time>.
    local work tmp
    work=$(mktemp -d /tmp/cipi-sync.XXXXXXXXXX) && [[ -n "$work" && -d "$work" ]] || { error "Cannot create a temporary directory under /tmp"; exit 1; }
    chmod 700 "$work"
    tmp="${work}/cipi-sync-${ts}"
    mkdir -p "${tmp}/config" "${tmp}/apps"

    # 1. Filter apps.json to only included apps (decrypt for export)
    step "Config files..."
    local apps_filter; apps_filter=$(printf '%s\n' "${apps[@]}" | jq -R . | jq -s .)
    vault_read apps.json | jq --argjson sel "$apps_filter" \
        'with_entries(select(.key as $k | $sel | index($k) != null))' \
        > "${tmp}/config/apps.json"

    # databases.json: include app DBs + standalone DBs that match app names
    [[ -f "${CIPI_CONFIG}/databases.json" ]] && vault_read databases.json > "${tmp}/config/databases.json"

    # Optional configs (decrypt for export)
    [[ -f "${CIPI_CONFIG}/backup.json" ]] && vault_read backup.json > "${tmp}/config/backup.json"
    [[ -f "${CIPI_CONFIG}/api.json" ]]    && vault_read api.json    > "${tmp}/config/api.json"
    [[ -f "${CIPI_CONFIG}/smtp.json" ]]   && vault_read smtp.json   > "${tmp}/config/smtp.json"
    [[ -f "${CIPI_CONFIG}/version" ]]     && cp "${CIPI_CONFIG}/version" "${tmp}/config/version"
    success "Config files"

    # 2. Per-app data
    if [[ "$with_db" == "true" ]]; then
        # shellcheck source=/dev/null
        source "${CIPI_LIB}/db.sh"
    fi

    for app in "${apps[@]}"; do
        local ad="${tmp}/apps/${app}"
        mkdir -p "${ad}/ssh"
        step "Exporting '${app}'..."

        # The app's files are read as the app's user (app_as in common.sh).
        # As root, cp followed a symlink in place of .env, auth.json or a key,
        # and tar -C went wherever `shared` led: the archive — which becomes
        # the app's own files on the server that imports it — carried
        # whatever they pointed at.

        # .env
        _sync_export_copy "$app" "/home/${app}/shared/.env" "${ad}/env"

        # auth.json
        _sync_export_copy "$app" "/home/${app}/shared/auth.json" "${ad}/auth.json"

        # Deployer config
        _sync_export_copy "$app" "/home/${app}/.deployer/deploy.php" "${ad}/deploy.php"

        # SSH keys
        for f in id_ed25519 id_ed25519.pub known_hosts config authorized_keys; do
            _sync_export_copy "$app" "/home/${app}/.ssh/${f}" "${ad}/ssh/${f}"
        done

        # Supervisor config
        [[ -f "/etc/supervisor/conf.d/${app}.conf" ]] && cp "/etc/supervisor/conf.d/${app}.conf" "${ad}/supervisor.conf"

        # Crontab
        crontab -u "$app" -l 2>/dev/null > "${ad}/crontab" || true
        [[ ! -s "${ad}/crontab" ]] && rm -f "${ad}/crontab"

        # Database dump
        if [[ "$with_db" == "true" ]] && [[ "$(app_get "$app" custom)" != "true" ]]; then
            step "  Database dump..."
            local eng; eng=$(app_get "$app" engine); [[ -z "$eng" ]] && eng="mariadb"
            eng=$(db_normalize_engine "$eng" 2>/dev/null || echo "mariadb")
            echo "$eng" > "${ad}/db.engine"
            if db_engine_is_installed "$eng" && db_dump_database "$eng" "$app" "${ad}/db.sql.gz"; then
                local sz; sz=$(du -h "${ad}/db.sql.gz" | cut -f1)
                success "  Database (${eng}, ${sz})"
            else
                warn "  Database dump failed (skipping)"
                rm -f "${ad}/db.sql.gz"
            fi
        fi

        # Shared storage
        if [[ "$with_storage" == "true" ]]; then
            step "  Shared storage..."
            if [[ -d "/home/${app}/shared/storage" ]]; then
                if _sync_export_storage "$app" "${ad}/storage.tar.gz"; then
                    local sz; sz=$(du -h "${ad}/storage.tar.gz" | cut -f1)
                    success "  Storage (${sz})"
                else
                    warn "  Storage archive failed (skipping)"
                    rm -f "${ad}/storage.tar.gz"
                fi
            else
                info "  No storage directory"
            fi
        fi

        success "'${app}'"
    done

    # 3. Manifest
    local ip; ip=$(curl -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null || echo "unknown")
    jq -n \
        --arg ver "$CIPI_VERSION" \
        --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg host "$hostname" \
        --arg ip "$ip" \
        --argjson apps "$apps_filter" \
        --arg with_db "$with_db" \
        --arg with_storage "$with_storage" \
        '{
            cipi_version: $ver,
            exported_at: $ts,
            hostname: $host,
            ip: $ip,
            apps: $apps,
            with_db: ($with_db == "true"),
            with_storage: ($with_storage == "true")
        }' > "${tmp}/manifest.json"

    # 4. Create encrypted archive
    step "Creating archive..."
    if [[ -z "$passphrase" ]]; then
        echo ""
        while true; do
            read -rsp "  Enter passphrase to encrypt the archive: " passphrase; echo
            [[ ${#passphrase} -ge 8 ]] && break
            warn "Passphrase must be at least 8 characters"
        done
        local passphrase2=""
        read -rsp "  Confirm passphrase: " passphrase2; echo
        [[ "$passphrase" != "$passphrase2" ]] && { error "Passphrases do not match"; rm -rf "$work"; exit 1; }
    else
        [[ ${#passphrase} -lt 8 ]] && { error "Passphrase must be at least 8 characters"; rm -rf "$work"; exit 1; }
    fi

    archive="${archive%.tar.gz}.tar.gz.enc"
    # The passphrase goes to openssl in its environment, not on its command
    # line: `-pass pass:…` is in the process list, which every local user can
    # read for as long as the export runs — and the archive is in /tmp.
    tar -czf - -C "$work" "cipi-sync-${ts}" | \
        CIPI_SYNC_PASSPHRASE="$passphrase" openssl enc -aes-256-cbc -salt -pbkdf2 -pass env:CIPI_SYNC_PASSPHRASE -out "$archive"
    rm -rf "$work"

    local total_sz; total_sz=$(du -h "$archive" | cut -f1)
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${GREEN}${BOLD}EXPORT COMPLETE (encrypted)${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  File:     ${CYAN}${archive}${NC}"
    echo -e "  Size:     ${CYAN}${total_sz}${NC}"
    echo -e "  Apps:     ${CYAN}${#apps[@]}${NC} (${apps[*]})"
    echo -e "  Database: ${CYAN}${with_db}${NC}"
    echo -e "  Storage:  ${CYAN}${with_storage}${NC}"
    if [[ "$internal_push" != "true" ]]; then
        echo ""
        echo -e "  ${BOLD}Transfer to target server:${NC}"
        echo -e "  ${CYAN}scp -i /home/cipi/.ssh/id_ed25519 ${archive} cipi@<target>:/tmp/${NC}"
        echo -e "  ${DIM}(Run cipi sync trust on target first if needed)${NC}"
        echo ""
        echo -e "  ${BOLD}Then import:${NC}"
        echo -e "  ${CYAN}cipi sync import /tmp/$(basename "$archive")${NC}"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_action "SYNC EXPORT: ${#apps[@]} apps (${apps[*]}) db=${with_db} storage=${with_storage} → ${archive}"
    cipi_notify \
        "Cipi sync export on $(hostname)" \
        "Apps were exported.\n\nServer: $(hostname)\nApps: ${apps[*]}\nArchive: ${archive}\nWith DB: ${with_db}\nWith storage: ${with_storage}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        sync_export
    [[ "$internal_push" == "true" ]] && _SYNC_LAST_ARCHIVE="$archive"
    return 0
}

# ── LIST (inspect archive) ────────────────────────────────────

_sync_list() {
    parse_args "$@"
    local file="" passphrase="${ARG_passphrase:-}"
    for arg in "$@"; do
        [[ "$arg" == --* ]] && continue
        [[ -z "$file" ]] && file="$arg"
    done
    [[ -z "$file" ]] && { error "Usage: cipi sync list <archive.tar.gz[.enc]> [--passphrase=...]"; exit 1; }
    [[ ! -f "$file" ]] && { error "File not found: $file"; exit 1; }

    local tmp; tmp=$(mktemp -d)
    if ! tar -tzf "$file" &>/dev/null; then
        [[ -z "$passphrase" ]] && { read -rsp "Archive is encrypted. Enter passphrase: " passphrase; echo; }
        CIPI_SYNC_PASSPHRASE="$passphrase" openssl enc -d -aes-256-cbc -pbkdf2 -pass env:CIPI_SYNC_PASSPHRASE -in "$file" 2>/dev/null \
            | tar -xzf - -C "$tmp" 2>/dev/null || { error "Decryption failed or invalid archive"; rm -rf "$tmp"; exit 1; }
    else
        tar -xzf "$file" -C "$tmp" 2>/dev/null || { error "Invalid archive"; rm -rf "$tmp"; exit 1; }
    fi

    local base; base=$(ls "$tmp" | head -1)
    local dir="${tmp}/${base}"

    [[ ! -f "${dir}/manifest.json" ]] && { error "Not a Cipi sync archive (missing manifest)"; rm -rf "$tmp"; exit 1; }

    echo ""
    echo -e "${BOLD}Cipi Sync Archive${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local ver ts host ip with_db with_storage
    ver=$(jq -r '.cipi_version' "${dir}/manifest.json")
    ts=$(jq -r '.exported_at' "${dir}/manifest.json")
    host=$(jq -r '.hostname' "${dir}/manifest.json")
    ip=$(jq -r '.ip' "${dir}/manifest.json")
    with_db=$(jq -r '.with_db' "${dir}/manifest.json")
    with_storage=$(jq -r '.with_storage' "${dir}/manifest.json")

    printf "  %-14s ${CYAN}%s${NC}\n" "Cipi" "v${ver}"
    printf "  %-14s ${CYAN}%s${NC}\n" "Exported" "$ts"
    printf "  %-14s ${CYAN}%s${NC}\n" "Source" "${host} (${ip})"
    printf "  %-14s ${CYAN}%s${NC}\n" "Database" "$with_db"
    printf "  %-14s ${CYAN}%s${NC}\n" "Storage" "$with_storage"

    echo -e "\n  ${BOLD}Apps${NC}"
    tbl_start
    tbl_head "APP" "DOMAIN" "PHP" "DB" "STORAGE"
    local a d p has_db has_st
    while IFS=$'\t' read -r a d p; do
        [[ -n "$a" ]] || continue
        has_db="—"; has_st="—"
        [[ -f "${dir}/apps/${a}/db.sql.gz" ]] && has_db="${GREEN}yes${NC}"
        [[ -f "${dir}/apps/${a}/storage.tar.gz" ]] && has_st="${GREEN}yes${NC}"
        tbl_row "$a" "$d" "$p" "$has_db" "$has_st"
    done < <(jq -r 'to_entries[]|"\(.key)\t\(.value.domain)\t\(.value.php)"' "${dir}/config/apps.json" 2>/dev/null)
    tbl_print

    if [[ -f "${dir}/config/databases.json" ]] && [[ $(jq 'length' "${dir}/config/databases.json" 2>/dev/null) -gt 0 ]]; then
        echo -e "\n  ${BOLD}Standalone Databases${NC}"
        jq -r 'to_entries[]|"  \(.key) (user: \(.value.user))"' "${dir}/config/databases.json"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  Import all:      ${CYAN}cipi sync import $(basename "$file")${NC}"
    echo -e "  Import specific: ${CYAN}cipi sync import $(basename "$file") app1 app2${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    rm -rf "$tmp"
}

# ── IMPORT ────────────────────────────────────────────────────

_sync_import() {
    local file=""
    local -a selected_apps=()

    parse_args "$@"
    local run_deploy="${ARG_deploy:-false}"
    local skip_confirm="${ARG_yes:-false}"
    local update_mode="${ARG_update:-false}"
    local passphrase="${ARG_passphrase:-}"

    for arg in "$@"; do
        [[ "$arg" == --* ]] && continue
        if [[ -z "$file" && ( "$arg" == *.tar.gz || "$arg" == *.tar.gz.enc ) ]]; then
            file="$arg"
        else
            [[ -n "$arg" ]] && selected_apps+=("$arg")
        fi
    done

    [[ -z "$file" ]] && { error "Usage: cipi sync import <archive.tar.gz[.enc]> [app1 ...] [--update] [--deploy] [--yes] [--passphrase=...]"; exit 1; }
    [[ ! -f "$file" ]] && { error "File not found: $file"; exit 1; }

    # Extract archive (handle encrypted archives transparently)
    local tmp; tmp=$(mktemp -d)
    if ! tar -tzf "$file" &>/dev/null; then
        [[ -z "$passphrase" ]] && { read -rsp "Archive is encrypted. Enter passphrase: " passphrase; echo; }
        CIPI_SYNC_PASSPHRASE="$passphrase" openssl enc -d -aes-256-cbc -pbkdf2 -pass env:CIPI_SYNC_PASSPHRASE -in "$file" 2>/dev/null \
            | tar -xzf - -C "$tmp" 2>/dev/null || { error "Decryption failed or invalid archive"; rm -rf "$tmp"; exit 1; }
    else
        tar -xzf "$file" -C "$tmp" 2>/dev/null || { error "Invalid archive"; rm -rf "$tmp"; exit 1; }
    fi

    local base; base=$(ls "$tmp" | head -1)
    local dir="${tmp}/${base}"
    [[ ! -f "${dir}/manifest.json" ]] && { error "Not a Cipi sync archive"; rm -rf "$tmp"; exit 1; }

    # Read manifest
    local src_ver src_host src_ip
    src_ver=$(jq -r '.cipi_version' "${dir}/manifest.json")
    src_host=$(jq -r '.hostname' "${dir}/manifest.json")
    src_ip=$(jq -r '.ip' "${dir}/manifest.json")

    # Determine which apps to import
    local -a apps=()
    if [[ ${#selected_apps[@]} -gt 0 ]]; then
        for a in "${selected_apps[@]}"; do
            jq -e --arg a "$a" '.[$a]' "${dir}/config/apps.json" &>/dev/null || { error "App '$a' not in archive"; rm -rf "$tmp"; exit 1; }
            apps+=("$a")
        done
    else
        mapfile -t apps < <(jq -r 'keys[]' "${dir}/config/apps.json")
    fi

    local mode_label="Import"
    [[ "$update_mode" == "true" ]] && mode_label="Import/Update"

    echo ""
    echo -e "${BOLD}Cipi Sync ${mode_label}${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  Source:  ${CYAN}${src_host} (${src_ip}) — Cipi v${src_ver}${NC}"
    echo -e "  Target:  ${CYAN}$(hostname) — Cipi v${CIPI_VERSION}${NC}"
    echo -e "  Apps:    ${CYAN}${#apps[@]}${NC} (${apps[*]})"
    [[ "$update_mode" == "true" ]] && echo -e "  Mode:    ${CYAN}update existing + import new${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Pre-flight checks
    local -a warnings=() blocked=() existing=() new_apps=() domain_conflict_msgs=()
    for app in "${apps[@]}"; do
        local php_ver; php_ver=$(jq -r --arg a "$app" '.[$a].php' "${dir}/config/apps.json")
        if ! php_is_installed "$php_ver" 2>/dev/null; then
            warnings+=("  ${YELLOW}!${NC} '${app}' needs PHP ${php_ver} — not installed (run: cipi php install ${php_ver})")
        fi

        local app_is_existing=false
        if app_exists "$app" 2>/dev/null || id "$app" &>/dev/null 2>&1; then
            app_is_existing=true
        fi

        if [[ "$app_is_existing" == "true" ]]; then
            if [[ "$update_mode" == "true" ]]; then
                existing+=("$app")
            else
                blocked+=("$app")
            fi
        else
            new_apps+=("$app")
        fi

        # Domain conflict check (exclude self when updating)
        local dom aliases_arr exclude_self=""
        [[ "$app_is_existing" == "true" && "$update_mode" == "true" ]] && exclude_self="$app"
        dom=$(jq -r --arg a "$app" '.[$a].domain' "${dir}/config/apps.json")
        mapfile -t aliases_arr < <(jq -r --arg a "$app" '.[$a].aliases // [] | .[]' "${dir}/config/apps.json")
        local -a to_check=("$dom")
        to_check+=("${aliases_arr[@]}")
        for d in "${to_check[@]}"; do
            [[ -z "$d" ]] && continue
            if domain_is_used_by_other_app "$d" "$exclude_self" 2>/dev/null; then
                domain_conflict_msgs+=("  ${RED}✗${NC} '${app}' domain ${CYAN}${d}${NC} already used by app '${DOMAIN_USED_BY_APP}'")
                [[ ! " ${blocked[*]} " =~ " ${app} " ]] && blocked+=("$app")
            fi
            if domain_is_used_by_panel "$d" 2>/dev/null; then
                domain_conflict_msgs+=("  ${RED}✗${NC} '${app}' domain ${CYAN}${d}${NC} is used by ${DOMAIN_USED_BY_PANEL} on this server")
                [[ ! " ${blocked[*]} " =~ " ${app} " ]] && blocked+=("$app")
            fi
            for other in "${apps[@]}"; do
                [[ "$other" == "$app" ]] && continue
                local other_dom other_aliases
                other_dom=$(jq -r --arg a "$other" '.[$a].domain' "${dir}/config/apps.json")
                other_aliases=$(jq -r --arg a "$other" '.[$a].aliases // [] | join(" ")' "${dir}/config/apps.json")
                if [[ "$d" == "$other_dom" ]] || [[ " ${other_aliases} " == *" ${d} "* ]]; then
                    domain_conflict_msgs+=("  ${RED}✗${NC} '${app}' domain ${CYAN}${d}${NC} conflicts with app '${other}' in same import")
                    [[ ! " ${blocked[*]} " =~ " ${app} " ]] && blocked+=("$app")
                fi
            done
        done
    done

    if [[ ${#blocked[@]} -gt 0 ]]; then
        echo ""
        for dc in "${domain_conflict_msgs[@]}"; do echo -e "$dc"; done
        for b in "${blocked[@]}"; do
            if [[ ! " ${domain_conflict_msgs[*]} " =~ "'${b}'" ]]; then
                echo -e "  ${RED}✗${NC} '${b}' already exists on this server"
            fi
        done
        echo ""
        if [[ "$update_mode" != "true" ]]; then
            error "Cannot import: app(s) already exist or domain conflict."
            echo -e "  ${DIM}Use --update to update existing apps, or exclude them:${NC}"
        else
            error "Cannot import: domain conflict(s) detected."
        fi
        echo -e "  ${DIM}cipi sync import ${file} $(printf '%s ' "${apps[@]}" | sed "s/$(printf '%s ' "${blocked[@]}")//g")${NC}"
        rm -rf "$tmp"; exit 1
    fi

    if [[ ${#existing[@]} -gt 0 ]]; then
        echo ""
        for e in "${existing[@]}"; do
            echo -e "  ${YELLOW}↻${NC} '${e}' exists — will be ${BOLD}updated${NC}"
        done
    fi
    if [[ ${#new_apps[@]} -gt 0 ]]; then
        echo ""
        for n in "${new_apps[@]}"; do
            echo -e "  ${GREEN}+${NC} '${n}' — will be ${BOLD}created${NC}"
        done
    fi

    if [[ ${#warnings[@]} -gt 0 ]]; then
        echo ""
        for w in "${warnings[@]}"; do echo -e "$w"; done
    fi

    if [[ "$skip_confirm" != "true" ]]; then
        echo ""
        confirm "${mode_label} ${#apps[@]} app(s)?" || { info "Cancelled"; rm -rf "$tmp"; exit 0; }
    fi

    echo ""
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/db.sh"
    local -a imported=() updated=() failed=()
    source "${CIPI_LIB}/app.sh"

    for app in "${apps[@]}"; do
        local ad="${dir}/apps/${app}"
        local php_ver domain branch repository
        php_ver=$(jq -r --arg a "$app" '.[$a].php' "${dir}/config/apps.json")
        domain=$(jq -r --arg a "$app" '.[$a].domain' "${dir}/config/apps.json")
        branch=$(jq -r --arg a "$app" '.[$a].branch // "main"' "${dir}/config/apps.json")
        repository=$(jq -r --arg a "$app" '.[$a].repository' "${dir}/config/apps.json")
        local home="/home/${app}"

        if ! php_is_installed "$php_ver" 2>/dev/null; then
            warn "PHP ${php_ver} not installed — skipping '${app}'"
            failed+=("$app")
            continue
        fi

        # Route: update existing or create new
        if [[ " ${existing[*]} " =~ " ${app} " ]]; then
            _sync_update_app "$app" "$ad" "$dir" "$php_ver" "$domain" "$branch" "$repository" "" "$run_deploy"
            updated+=("$app")
        else
            _sync_create_app "$app" "$ad" "$dir" "$php_ver" "$domain" "$branch" "$repository" "" "$run_deploy"
            imported+=("$app")
        fi
    done

    rm -rf "$tmp"

    # Remove archive after successful import/update (frees disk space)
    if [[ ${#imported[@]} -gt 0 || ${#updated[@]} -gt 0 ]]; then
        rm -f "$file"
    fi

    # Summary
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${GREEN}${BOLD}${mode_label^^} COMPLETE${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    [[ ${#imported[@]} -gt 0 ]] && echo -e "  Created: ${CYAN}${#imported[@]}${NC} (${imported[*]})"
    [[ ${#updated[@]} -gt 0 ]] && echo -e "  Updated: ${CYAN}${#updated[@]}${NC} (${updated[*]})"
    [[ ${#failed[@]} -gt 0 ]]  && echo -e "  Failed:  ${RED}${#failed[@]}${NC} (${failed[*]})"
    echo ""
    if [[ "$run_deploy" != "true" && ${#imported[@]} -gt 0 ]]; then
        echo -e "  ${BOLD}Next steps for new apps:${NC}"
        for a in "${imported[@]}"; do
            echo -e "    ${CYAN}cipi deploy ${a}${NC}"
        done
        echo -e "    ${CYAN}cipi ssl install <app>${NC}  (for each app)"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    log_action "SYNC IMPORT: created=${#imported[@]} (${imported[*]}) updated=${#updated[@]} (${updated[*]}) from ${src_host} (${src_ip})"
    cipi_notify \
        "Cipi sync import on $(hostname)" \
        "Apps were imported.\n\nServer: $(hostname)\nCreated: ${imported[*]:-none}\nUpdated: ${updated[*]:-none}\nFrom: ${src_host} (${src_ip})\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        sync_import
}

# apps.json arrives with the source's yml_auto, but /etc/sudoers.d does not
# travel: without its rule a webhook deploy here would skip cipi.yml while
# `cipi deploy` applied it. Bring the rule in line with the imported flag.
_sync_yml_auto_sudoers() {
    local app="$1"
    # shellcheck source=/dev/null
    declare -f yml_auto_sudoers_sync >/dev/null 2>&1 || source "${CIPI_LIB}/yml.sh"
    yml_auto_sudoers_sync "$app" \
        || warn "cipi.yml auto-apply: sudoers rule rejected for '${app}' — run: cipi yml auto ${app} on"
}

# ── CREATE APP (fresh import) ─────────────────────────────────

# ~/logs/<name> → /var/log/cipi-apps/<app>/<name> for every log the app's
# restored supervisor file names.
_sync_supervisor_log_links() {
    local app="$1" n
    local -a names=()
    while IFS= read -r n; do
        [[ -n "$n" ]] && names+=("$n")
    done < <(sed -n "s#^stdout_logfile=/var/log/cipi-apps/${app}/\\([A-Za-z0-9._-]*\\)\$#\\1#p" "/etc/supervisor/conf.d/${app}.conf" 2>/dev/null | sort -u)
    [[ ${#names[@]} -gt 0 ]] && app_log_links "$app" "${names[@]}"
    return 0
}

_sync_create_app() {
    local app="$1" ad="$2" dir="$3" php_ver="$4" domain="$5" branch="$6" repository="$7" dbr="$8" run_deploy="$9"
    local home="/home/${app}"

    if [[ "$(jq -r --arg a "$app" '.[$a].runtime // empty' "${dir}/config/apps.json" 2>/dev/null)" == "node" ]]; then
        warn "'${app}' is a Node app — sync does not recreate those yet. Here: cipi app create --node=… then cipi deploy ${app}"
        return 0
    fi
    echo -e "\n${BOLD}Creating '${app}'...${NC}"
    echo "────────────────────────────────────────────────"

    # 1. Linux user
    step "User..."
    local user_pass; user_pass=$(generate_password 40)
    # Not in www-data: see `cipi app create` (lib/app.sh).
    useradd -m -s /bin/bash -G cipi-apps "$app"
    app_ssh_apply_default "$app"
    echo "${app}:${user_pass}" | chpasswd
    chmod 750 "$home"
    usermod -aG "$app" www-data
    success "User"

    # 2. Directories
    step "Directories..."
    mkdir -p "${home}"/{shared/storage/{app/public,framework/{cache/data,sessions,views},logs},logs,.ssh,.deployer}
    cat > "${home}/.bashrc" <<BASH
export PATH="/usr/local/bin:\$PATH"
alias php='/usr/bin/php${php_ver}'
alias artisan='php ${home}/current/artisan'
alias composer='/usr/bin/php${php_ver} /usr/local/bin/composer'
alias tinker='artisan tinker'
alias deploy='/usr/bin/php${php_ver} /usr/local/bin/dep deploy -f ${home}/.deployer/deploy.php'
PS1='\[\033[0;32m\]\u\[\033[0m\]@\h:\[\033[0;34m\]\w\[\033[0m\]\$ '
BASH
    success "Directories"

    # 3. SSH keys
    step "SSH keys..."
    if [[ -d "${ad}/ssh" ]]; then
        for f in id_ed25519 id_ed25519.pub known_hosts config authorized_keys; do
            [[ -f "${ad}/ssh/${f}" ]] && cp "${ad}/ssh/${f}" "${home}/.ssh/${f}"
        done
        chmod 700 "${home}/.ssh"
        chmod 600 "${home}/.ssh/"* 2>/dev/null || true
        ssh-keyscan -H localhost 127.0.0.1 2>/dev/null >> "${home}/.ssh/known_hosts"
        success "SSH keys (restored from source)"
    else
        sudo -u "$app" ssh-keygen -t ed25519 -C "${app}@cipi" -f "${home}/.ssh/id_ed25519" -N "" -q
        cat "${home}/.ssh/id_ed25519.pub" >> "${home}/.ssh/authorized_keys"
        source "${CIPI_LIB}/git.sh"
        local _sync_repo=""
        _sync_repo=$(jq -r --arg a "$app" '.[$a].repository // empty' "${dir}/config/apps.json" 2>/dev/null || true)
        git_seed_app_known_hosts "${home}/.ssh/known_hosts" "$_sync_repo"
        chmod 600 "${home}/.ssh/authorized_keys" "${home}/.ssh/known_hosts"
        warn "SSH keys (generated new — update deploy key on git provider)"
    fi

    # 4. Database
    local eng db_pass db_conn db_port
    eng=$(jq -r --arg a "$app" '.[$a].engine // "mariadb"' "${dir}/config/apps.json" 2>/dev/null)
    [[ -f "${ad}/db.engine" ]] && eng=$(cat "${ad}/db.engine")
    eng=$(db_normalize_engine "$eng" 2>/dev/null || echo "mariadb")
    if ! db_engine_is_installed "$eng"; then
        error "App '${app}' requires ${eng} but it is not installed. Run: cipi db install ${eng}"
        return 1
    fi
    step "Database ($(db_engine_label "$eng"))..."
    db_pass=$(generate_password 40)
    db_create_database "$eng" "$app" "$app" "$db_pass" || { error "Database create failed"; return 1; }
    success "Database (new credentials, ${eng})"

    # 5. DB dump
    if [[ -f "${ad}/db.sql.gz" ]]; then
        step "Restoring database..."
        if db_restore_database "$eng" "$app" "${ad}/db.sql.gz"; then
            success "Database data restored"
        else
            warn "Database restore had issues"
        fi
    fi

    # 6. .env
    step ".env..."
    db_conn=$(db_engine_laravel_connection "$eng")
    db_port=$(db_engine_port "$eng")
    if [[ -f "${ad}/env" ]]; then
        cp "${ad}/env" "${home}/shared/.env"
        sed -i "s|^DB_CONNECTION=.*|DB_CONNECTION=${db_conn}|" "${home}/shared/.env"
        sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=${db_pass}|" "${home}/shared/.env"
        sed -i "s|^DB_USERNAME=.*|DB_USERNAME=${app}|" "${home}/shared/.env"
        sed -i "s|^DB_DATABASE=.*|DB_DATABASE=${app}|" "${home}/shared/.env"
        sed -i "s|^DB_HOST=.*|DB_HOST=127.0.0.1|" "${home}/shared/.env"
        if grep -q '^DB_PORT=' "${home}/shared/.env"; then
            sed -i "s|^DB_PORT=.*|DB_PORT=${db_port}|" "${home}/shared/.env"
        else
            sed -i "/^DB_HOST=/a DB_PORT=${db_port}" "${home}/shared/.env"
        fi
        success ".env (restored, DB credentials updated)"
    else
        warn "No .env in archive"
    fi

    # 7. auth.json
    [[ -f "${ad}/auth.json" ]] && { cp "${ad}/auth.json" "${home}/shared/auth.json"; success "auth.json"; }

    # 8. Storage
    if [[ -f "${ad}/storage.tar.gz" ]]; then
        step "Storage..."
        tar -xzf "${ad}/storage.tar.gz" -C "${home}/shared/" 2>/dev/null && success "Storage restored" || warn "Storage failed"
    fi

    # 9. Ownership
    chown -R "${app}:${app}" "$home"
    # A source server not yet on 5.5.0 still exports LOG_CHANNEL=daily, and
    # dated Laravel logs that came with the storage go into laravel.log.
    laravel_app_env_single_log "$app" || true
    laravel_logs_unify "$app" >/dev/null || true
    ensure_app_logs_permissions "$app"

    # 10. apps.json
    local app_json
    app_json=$(jq --arg a "$app" --arg e "$eng" '.[$a] + {engine: (.[$a].engine // $e)}' "${dir}/config/apps.json")
    app_save "$app" "$app_json"
    # The webhook of cipi/agent reads the deploy branch from .env (5.7.2).
    if [[ "$(app_get "$app" runtime)" != "node" ]]; then
        app_env_set_deploy_branch "$app" "$branch"
    fi
    # The post-deploy runner reads the environment label from .env (5.8.0).
    app_env_set_environment "$app" "$(app_env_label "$app")" || true
    # Its own Valkey on this server (5.9.0): the REDIS_* lines it arrived
    # with name the server it left.
    if [[ -f "${CIPI_LIB}/valkey.sh" && "$(app_get "$app" custom)" != "true" ]]; then
        # shellcheck source=/dev/null
        source "${CIPI_LIB}/valkey.sh"
        valkey_sync_adopt "$app" || true
    fi

    # 11. PHP-FPM (skipped for Octane apps)
    local sync_octane sync_octane_port
    sync_octane=$(echo "$app_json" | jq -r '.octane // empty')
    sync_octane_port=$(echo "$app_json" | jq -r '.octane_port // empty')
    if [[ -n "$sync_octane" ]]; then
        step "PHP-FPM..."
        success "Skipped (Octane)"
        _ensure_nginx_octane_map
    else
        step "PHP-FPM..."
        _create_fpm_pool "$app" "$php_ver"
        reload_php_fpm "$php_ver"
        success "PHP-FPM ${php_ver}"
    fi

    # 12. Nginx
    step "Nginx..."
    _create_nginx_vhost "$app" "$domain" "$php_ver"
    ln -sf "/etc/nginx/sites-available/${app}" "/etc/nginx/sites-enabled/${app}"
    reload_nginx
    success "Nginx → ${domain}"

    # 13. Supervisor
    step "Workers..."
    if [[ -f "${ad}/supervisor.conf" ]] && [[ -s "${ad}/supervisor.conf" ]]; then
        # A file exported before 5.9.0 logs to ~/logs: root's directory instead
        # (app_log_dir in common.sh), with the symlinks in ~/logs.
        app_log_dir_ensure "$app" || true
        sed -e "s|/usr/bin/php[0-9]\.[0-9]|/usr/bin/php${php_ver}|g" \
            -e "s|^stdout_logfile=/home/${app}/logs/|stdout_logfile=/var/log/cipi-apps/${app}/|" "${ad}/supervisor.conf" \
            > "/etc/supervisor/conf.d/${app}.conf"
        _sync_supervisor_log_links "$app"
        success "Workers (restored)"
    else
        echo "" > "/etc/supervisor/conf.d/${app}.conf"
        _create_supervisor_worker "$app" "$php_ver" "default"
        if [[ -n "$sync_octane" && -n "$sync_octane_port" ]]; then
            _create_supervisor_octane "$app" "$php_ver" "$sync_octane_port"
            success "Worker + Octane (:${sync_octane_port})"
        else
            success "Worker (default)"
        fi
    fi
    reload_supervisor

    # 14. Crontab (respect schedule=off)
    step "Crontab..."
    local sync_schedule
    sync_schedule=$(echo "$app_json" | jq -r '.schedule // "on"')
    local schedule_block="# Laravel Scheduler (disabled by cipi schedule off)
"
    if [[ "$sync_schedule" != "off" ]]; then
        schedule_block="# Laravel Scheduler
* * * * * /usr/bin/php${php_ver} ${home}/current/artisan schedule:run >> /dev/null 2>&1
"
    fi
    cat <<CRON | crontab -u "$app" -
${schedule_block}# Cipi deploy trigger
* * * * * test -f ${home}/.deploy-trigger && mv -f ${home}/.deploy-trigger ${home}/.deploy-trigger.run && /usr/local/bin/cipi-app-deploy ${app} ${php_ver} webhook >/dev/null 2>&1
CRON
    # Restore reverb/horizon/octane supervisor extras when conf was empty
    if [[ ! -f "${ad}/supervisor.conf" ]] || [[ ! -s "${ad}/supervisor.conf" ]]; then
        local sync_reverb sync_reverb_port sync_horizon
        sync_reverb=$(echo "$app_json" | jq -r '.reverb // empty')
        sync_reverb_port=$(echo "$app_json" | jq -r '.reverb_port // empty')
        sync_horizon=$(echo "$app_json" | jq -r '.horizon // empty')
        if [[ "$sync_horizon" == "true" ]]; then
            _supervisor_remove_program "$app" "${app}-worker-default" 2>/dev/null || true
            _create_supervisor_horizon "$app" "$php_ver"
        fi
        if [[ -n "$sync_reverb" && -n "$sync_reverb_port" ]]; then
            _create_supervisor_reverb "$app" "$php_ver" "$sync_reverb_port"
        fi
        reload_supervisor
    fi
    success "Crontab"

    # 15. Deployer
    step "Deployer..."
    if [[ -f "${ad}/deploy.php" ]]; then
        mkdir -p "${home}/.deployer"
        cp "${ad}/deploy.php" "${home}/.deployer/deploy.php"
        sed -i "s|set('bin/php', '/usr/bin/php[0-9]\.[0-9]')|set('bin/php', '/usr/bin/php${php_ver}')|" \
            "${home}/.deployer/deploy.php"
        sed -i "s|set('bin/composer', '/usr/bin/php[0-9]\.[0-9] /usr/local/bin/composer')|set('bin/composer', '/usr/bin/php${php_ver} /usr/local/bin/composer')|" \
            "${home}/.deployer/deploy.php"
        if ! grep -q "bin/composer" "${home}/.deployer/deploy.php" 2>/dev/null; then
            sed -i "/set('bin\/php'/a set('bin/composer', '/usr/bin/php${php_ver} /usr/local/bin/composer');" "${home}/.deployer/deploy.php"
        fi
        deployer_audit_ensure_hook "$app" || true
        deployer_unlock_ensure_hook "$app" || true
        deployer_release_name_ensure_hook "$app" || true
        chown -R "${app}:${app}" "${home}/.deployer"
        success "Deployer (restored)"
    else
        _create_deployer_config_for_app "$app"
        success "Deployer (recreated)"
    fi

    # 16. Sudoers
    cat > "/etc/sudoers.d/cipi-${app}" <<SUDO
${app} ALL=(root) NOPASSWD: /usr/local/bin/cipi-worker restart ${app}
${app} ALL=(root) NOPASSWD: /usr/local/bin/cipi-worker stop ${app}
${app} ALL=(root) NOPASSWD: /usr/local/bin/cipi-worker status ${app}
${app} ALL=(root) NOPASSWD: /usr/local/bin/cipi-scan-manifest ${app}
${app} ALL=(root) NOPASSWD: /usr/local/bin/cipi-deploy-audit ${app} *
SUDO
    chmod 440 "/etc/sudoers.d/cipi-${app}"
    _sync_yml_auto_sudoers "$app"

    # 17. Deploy
    if [[ "$run_deploy" == "true" ]]; then
        step "Deploying..."
        if CIPI_DEPLOY_TRIGGER=sync sudo -u "$app" bash -c "cd ${home} && /usr/bin/php${php_ver} /usr/local/bin/dep deploy -f ${home}/.deployer/deploy.php" 2>&1; then
            success "Deploy completed"
        else
            warn "Deploy failed — run manually: cipi deploy ${app}"
        fi
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}✓ '${app}' created${NC}"
    echo -e "  SSH password: ${CYAN}${user_pass}${NC}"
    echo -e "  DB password:  ${CYAN}${db_pass}${NC}"
    echo -e "  ${YELLOW}⚠ Save these credentials!${NC}"
}

# ── UPDATE APP (incremental sync) ────────────────────────────

_sync_update_app() {
    local app="$1" ad="$2" dir="$3" php_ver="$4" domain="$5" branch="$6" repository="$7" dbr="$8" run_deploy="$9"
    local home="/home/${app}"

    if [[ "$(app_get "$app" runtime)" == "node" ]]; then
        warn "'${app}' is a Node app — skipped (sync does not handle Node apps yet)"
        return 0
    fi
    echo -e "\n${BOLD}Updating '${app}'...${NC}"
    echo "────────────────────────────────────────────────"

    local cur_php; cur_php=$(app_get "$app" php)

    # 1. .env — sync from source but preserve local DB credentials
    if [[ -f "${ad}/env" ]]; then
        step ".env..."
        # This app exists: its .env is read and written as its own user
        # (app_as in common.sh). And the values kept from it are data, never
        # part of a sed script: root pasted them into one, where a "|e" in a
        # DB_PASSWORD line of the app's .env ran a command as root.
        local local_db_pass local_db_user local_db_name local_db_host local_db_port local_db_conn env_cur=""
        local local_redis_host local_redis_port local_redis_pass
        env_cur=$(app_read "$app" "${home}/shared/.env") || env_cur=""
        # Valkey is this server's too (5.9.0): the app's own instance, or
        # the shared one with this server's password — never the source's.
        local_redis_host=$(grep -m1 '^REDIS_HOST=' <<< "$env_cur" | cut -d= -f2- || true)
        local_redis_port=$(grep -m1 '^REDIS_PORT=' <<< "$env_cur" | cut -d= -f2- || true)
        local_redis_pass=$(grep -m1 '^REDIS_PASSWORD=' <<< "$env_cur" | cut -d= -f2- || true)
        # `|| true`: a key this .env does not have (an SQLite app has no
        # DB_HOST) is an empty value here, not the end of the command — under
        # pipefail the failed grep stopped `cipi sync` right here, in silence.
        local_db_pass=$(grep -m1 '^DB_PASSWORD=' <<< "$env_cur" | cut -d= -f2- || true)
        local_db_user=$(grep -m1 '^DB_USERNAME=' <<< "$env_cur" | cut -d= -f2- || true)
        local_db_name=$(grep -m1 '^DB_DATABASE=' <<< "$env_cur" | cut -d= -f2- || true)
        local_db_host=$(grep -m1 '^DB_HOST=' <<< "$env_cur" | cut -d= -f2- || true)
        local_db_port=$(grep -m1 '^DB_PORT=' <<< "$env_cur" | cut -d= -f2- || true)
        local_db_conn=$(grep -m1 '^DB_CONNECTION=' <<< "$env_cur" | cut -d= -f2- || true)
        # The source's .env with the local DB credentials put back, in one write.
        CIPI_KEEP_DB_PASSWORD="$local_db_pass" CIPI_KEEP_DB_USERNAME="$local_db_user" \
        CIPI_KEEP_DB_DATABASE="$local_db_name" CIPI_KEEP_DB_HOST="$local_db_host" \
        CIPI_KEEP_DB_PORT="$local_db_port" CIPI_KEEP_DB_CONNECTION="$local_db_conn" \
        CIPI_KEEP_REDIS_HOST="$local_redis_host" CIPI_KEEP_REDIS_PORT="$local_redis_port" \
        CIPI_KEEP_REDIS_PASSWORD="$local_redis_pass" \
        awk 'BEGIN {
                 n = split("DB_PASSWORD DB_USERNAME DB_DATABASE DB_HOST DB_PORT DB_CONNECTION REDIS_HOST REDIS_PORT REDIS_PASSWORD", k, " ")
                 for (i = 1; i <= n; i++) if (ENVIRON["CIPI_KEEP_" k[i]] != "") keep[k[i]] = ENVIRON["CIPI_KEEP_" k[i]]
             }
             { i = index($0, "="); key = (i > 1 ? substr($0, 1, i - 1) : "")
               if (key in keep) print key "=" keep[key]; else print }' "${ad}/env" \
            | app_write "$app" "${home}/shared/.env" 640
        laravel_app_env_single_log "$app" || true
        success ".env (synced, local DB and Valkey credentials preserved)"
    fi

    # 2. auth.json
    if [[ -f "${ad}/auth.json" ]]; then
        app_write "$app" "${home}/shared/auth.json" 640 < "${ad}/auth.json"
        success "auth.json synced"
    fi

    # 3. DB dump — drop and reimport (same engine as local app)
    if [[ -f "${ad}/db.sql.gz" ]]; then
        step "Database sync..."
        local eng; eng=$(app_get "$app" engine); [[ -z "$eng" ]] && eng="mariadb"
        [[ -f "${ad}/db.engine" ]] && eng=$(cat "${ad}/db.engine")
        eng=$(db_normalize_engine "$eng" 2>/dev/null || echo "mariadb")
        if db_engine_is_installed "$eng" && db_restore_database "$eng" "$app" "${ad}/db.sql.gz"; then
            success "Database data synced (${eng})"
        else
            warn "Database sync had issues"
        fi
    fi

    # 4. Storage
    if [[ -f "${ad}/storage.tar.gz" ]]; then
        step "Storage sync..."
        # Unpacked by the app's user: root unpacked it into shared/ and then
        # ran chown -R on shared/storage — both through whatever `shared` was.
        _sync_import_storage "$app" "${ad}/storage.tar.gz" && \
            success "Storage synced" || warn "Storage sync failed"
        laravel_logs_unify "$app" >/dev/null || true
        ensure_app_logs_permissions "$app"
    fi

    # 5. PHP version change
    if [[ "$php_ver" != "$cur_php" ]]; then
        step "PHP ${cur_php} → ${php_ver}..."
        if [[ -n "$(app_get "$app" octane)" ]]; then
            rm -f "/etc/php/${cur_php}/fpm/pool.d/${app}.conf" 2>/dev/null || true
        else
            rm -f "/etc/php/${cur_php}/fpm/pool.d/${app}.conf"
            _create_fpm_pool "$app" "$php_ver"
            reload_php_fpm "$cur_php" 2>/dev/null || true
            reload_php_fpm "$php_ver"
        fi
        sed -i "s|/usr/bin/php[0-9]\.[0-9]|/usr/bin/php${php_ver}|g" "/etc/supervisor/conf.d/${app}.conf" 2>/dev/null
        reload_supervisor
        crontab -u "$app" -l 2>/dev/null | sed "s|php${cur_php}|php${php_ver}|g" | crontab -u "$app" -
        # The app's own files, edited as the app's user.
        app_sed "$app" "${home}/.bashrc" "s|php${cur_php}|php${php_ver}|g" 2>/dev/null
        app_sed "$app" "${home}/.deployer/deploy.php" \
            -e "s|set('bin/php', '/usr/bin/php[0-9]\.[0-9]')|set('bin/php', '/usr/bin/php${php_ver}')|" \
            -e "s|set('bin/composer', '/usr/bin/php[0-9]\.[0-9] /usr/local/bin/composer')|set('bin/composer', '/usr/bin/php${php_ver} /usr/local/bin/composer')|" 2>/dev/null
        local dp_now=""
        dp_now=$(app_read "$app" "${home}/.deployer/deploy.php") || dp_now=""
        if ! grep -q "bin/composer" <<< "$dp_now"; then
            app_sed "$app" "${home}/.deployer/deploy.php" "/set('bin\/php'/a set('bin/composer', '/usr/bin/php${php_ver} /usr/local/bin/composer');" 2>/dev/null
        fi
        app_sed "$app" "${home}/shared/.env" "s|^CIPI_PHP_VERSION=.*|CIPI_PHP_VERSION=${php_ver}|" 2>/dev/null
        success "PHP → ${php_ver}"
    fi

    # 6. Update apps.json (aliases, branch, repository, etc.)
    local app_json; app_json=$(jq --arg a "$app" '.[$a]' "${dir}/config/apps.json")
    app_save "$app" "$app_json"
    # valkey_port came with the entry: what counts is the instance here.
    if [[ -f "${CIPI_LIB}/valkey.sh" ]]; then
        # shellcheck source=/dev/null
        source "${CIPI_LIB}/valkey.sh"
        valkey_sync_keep "$app" || true
    fi
    _sync_yml_auto_sudoers "$app"
    # The webhook of cipi/agent reads the deploy branch from .env (5.7.2).
    if [[ "$(app_get "$app" runtime)" != "node" ]]; then
        app_env_set_deploy_branch "$app" "$branch"
    fi
    # The post-deploy runner reads the environment label from .env (5.8.0).
    app_env_set_environment "$app" "$(app_env_label "$app")" || true

    # 7. Regenerate nginx vhost (picks up alias changes / Octane proxy)
    step "Nginx..."
    [[ -n "$(app_get "$app" octane)" ]] && _ensure_nginx_octane_map
    _create_nginx_vhost "$app" "$domain" "$php_ver"
    ln -sf "/etc/nginx/sites-available/${app}" "/etc/nginx/sites-enabled/${app}"
    reload_nginx
    success "Nginx → ${domain}"

    # 8. Supervisor (restore if changed)
    if [[ -f "${ad}/supervisor.conf" ]] && [[ -s "${ad}/supervisor.conf" ]]; then
        step "Workers..."
        app_log_dir_ensure "$app" || true
        sed -e "s|/usr/bin/php[0-9]\.[0-9]|/usr/bin/php${php_ver}|g" \
            -e "s|^stdout_logfile=/home/${app}/logs/|stdout_logfile=/var/log/cipi-apps/${app}/|" "${ad}/supervisor.conf" \
            > "/etc/supervisor/conf.d/${app}.conf"
        _sync_supervisor_log_links "$app"
        reload_supervisor
        success "Workers synced"
    fi

    # 9. Deployer config
    if [[ -f "${ad}/deploy.php" ]]; then
        step "Deployer..."
        # Prepared in a file of root's, then written by the app's user.
        local dp_tmp; dp_tmp=$(mktemp)
        sed -e "s|set('bin/php', '/usr/bin/php[0-9]\.[0-9]')|set('bin/php', '/usr/bin/php${php_ver}')|" \
            -e "s|set('bin/composer', '/usr/bin/php[0-9]\.[0-9] /usr/local/bin/composer')|set('bin/composer', '/usr/bin/php${php_ver} /usr/local/bin/composer')|" \
            "${ad}/deploy.php" > "$dp_tmp"
        if ! grep -q "bin/composer" "$dp_tmp" 2>/dev/null; then
            sed -i "/set('bin\/php'/a set('bin/composer', '/usr/bin/php${php_ver} /usr/local/bin/composer');" "$dp_tmp"
        fi
        local dp_rc=0
        app_write "$app" "${home}/.deployer/deploy.php" < "$dp_tmp" || dp_rc=$?
        rm -f "$dp_tmp"
        [[ $dp_rc -eq 0 ]] || { error "Cannot write ${home}/.deployer/deploy.php"; exit 1; }
        success "Deployer synced"
    fi

    # 10. Fix ownership
    chown -h -R "${app}:${app}" "${home}/shared" "${home}/.deployer" "${home}/.ssh" "${home}/.bashrc" 2>/dev/null

    # 11. Deploy
    if [[ "$run_deploy" == "true" ]]; then
        step "Deploying..."
        if CIPI_DEPLOY_TRIGGER=sync sudo -u "$app" bash -c "cd ${home} && /usr/bin/php${php_ver} /usr/local/bin/dep deploy -f ${home}/.deployer/deploy.php" 2>&1; then
            success "Deploy completed"
        else
            warn "Deploy failed — run manually: cipi deploy ${app}"
        fi
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}↻ '${app}' updated${NC}"
}

# ── PUSH (export + transfer + optional remote import) ─────────

_sync_push() {
    parse_args "$@"

    local remote_host="${ARG_host:-}" remote_port="${ARG_port:-}" remote_user="${ARG_user:-cipi}"
    local remote_import="${ARG_import:-false}"
    local with_db="${ARG_with_db:-false}"
    local with_storage="${ARG_with_storage:-false}"
    local passphrase="${ARG_passphrase:-}"

    # Collect app names (positional args, excluding --flags)
    local -a app_args=()
    for arg in "$@"; do
        [[ "$arg" == --* ]] && continue
        app_args+=("$arg")
    done

    # Interactive prompts for connection details
    [[ -z "$remote_host" ]] && read_input "Target server (IP or hostname)" "" remote_host
    [[ -z "$remote_host" ]] && { error "Target server required"; exit 1; }
    [[ -z "$remote_port" ]] && read_input "SSH port" "22" remote_port

    echo ""
    info "Target: ${remote_user}@${remote_host}:${remote_port}"

    # Use cipi's sync key (works when cipi is run as root)
    local ssh_identity="/home/cipi/.ssh/id_ed25519"
    local ssh_opts="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -p ${remote_port}"
    [[ -f "$ssh_identity" ]] && ssh_opts="-i ${ssh_identity} ${ssh_opts}"

    # Test SSH connectivity
    step "Testing SSH connection..."
    if ! ssh ${ssh_opts} -o BatchMode=yes "${remote_user}@${remote_host}" "echo ok" &>/dev/null; then
        echo ""
        warn "SSH key-based auth failed. Trying with password..."
        echo -e "${DIM}  You may be prompted for the password of ${remote_user}@${remote_host}${NC}"
        echo ""
        if ! ssh ${ssh_opts} "${remote_user}@${remote_host}" "echo ok" </dev/tty; then
            error "Cannot connect to ${remote_user}@${remote_host}:${remote_port}"
            echo ""
            echo -e "  ${BOLD}Troubleshooting:${NC}"
            echo -e "  ${DIM}1. Check the IP/hostname is correct${NC}"
            echo -e "  ${DIM}2. Ensure SSH is running on port ${remote_port}${NC}"
            echo -e "  ${DIM}3. Trust this server's key on remote: cipi sync trust${NC}"
            echo -e "  ${DIM}4. Show this server's public key: cipi sync pubkey${NC}"
            exit 1
        fi
    fi
    success "SSH connection OK"

    # Verify Cipi is installed on remote (use 'cipi version' — cipi can only sudo cipi *)
    step "Checking Cipi on remote..."
    local remote_ver
    remote_ver=$(ssh ${ssh_opts} "${remote_user}@${remote_host}" \
        "sudo cipi version 2>/dev/null" </dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
    if [[ -z "$remote_ver" ]]; then
        error "Cipi is not installed on ${remote_host}"
        echo -e "  ${DIM}Install it first: curl -sSL https://cipi.sh/setup.sh | sudo bash${NC}"
        exit 1
    fi
    success "Remote Cipi v${remote_ver}"

    # Build export flags (--internal-push suppresses manual transfer instructions)
    local -a export_flags=("--internal-push")
    [[ "$with_db" == "true" ]] && export_flags+=("--with-db")
    [[ "$with_storage" == "true" ]] && export_flags+=("--with-storage")
    [[ -n "$passphrase" ]] && export_flags+=("--passphrase=${passphrase}")

    # Run local export
    echo ""
    info "Phase 1: Export"
    echo "────────────────────────────────────────────────"
    _sync_export "${app_args[@]}" "${export_flags[@]}" 2>&1

    # Find the archive (use path from export when available, else glob)
    local archive
    if [[ -n "${_SYNC_LAST_ARCHIVE:-}" && -f "${_SYNC_LAST_ARCHIVE}" ]]; then
        archive="$_SYNC_LAST_ARCHIVE"
        _SYNC_LAST_ARCHIVE=""
    else
        archive=$(ls -t /tmp/cipi-sync-*.tar.gz.enc /tmp/cipi-sync-*.tar.gz 2>/dev/null | head -1)
    fi
    [[ -z "$archive" || ! -f "$archive" ]] && { error "Export archive not found"; exit 1; }

    local archive_name; archive_name=$(basename "$archive")
    local archive_sz; archive_sz=$(du -h "$archive" | cut -f1)

    # Transfer via rsync (falls back to scp) — run as cipi user so ~/.ssh/id_ed25519 is used
    echo ""
    info "Phase 2: Transfer (${archive_sz})"
    echo "────────────────────────────────────────────────"
    step "Sending ${archive_name} → ${remote_host}:/tmp/"

    local rsync_ssh="ssh -p ${remote_port} -o StrictHostKeyChecking=accept-new"
    local scp_opts="-P ${remote_port} -o StrictHostKeyChecking=accept-new"

    local transferred=false
    if command -v rsync &>/dev/null; then
        if sudo -u cipi rsync -az --progress -e "$rsync_ssh" \
                "$archive" "${remote_user}@${remote_host}:/tmp/${archive_name}"; then
            success "Transfer complete (rsync)"
            transferred=true
        else
            warn "rsync failed, trying scp..."
        fi
    fi
    if [[ "$transferred" != "true" ]]; then
        if sudo -u cipi scp ${scp_opts} "$archive" "${remote_user}@${remote_host}:/tmp/${archive_name}"; then
            success "Transfer complete (scp)"
            transferred=true
        fi
    fi
    if [[ "$transferred" != "true" ]]; then
        error "Transfer failed (tried rsync and scp)"
        echo -e "  ${DIM}Ensure cipi sync trust was run on ${remote_host}${NC}"
        echo -e "  ${DIM}Test manually: sudo -u cipi scp -P ${remote_port} ${archive} ${remote_user}@${remote_host}:/tmp/${NC}"
        exit 1
    fi

    # Clean up local archive
    rm -f "$archive"

    # Remote import (optional)
    if [[ "$remote_import" == "true" ]]; then
        echo ""
        info "Phase 3: Remote Import"
        echo "────────────────────────────────────────────────"
        local -a remote_cmd=("sudo" "cipi" "sync" "import" "/tmp/${archive_name}" "--yes" "--update")
        [[ -n "$passphrase" ]] && remote_cmd+=("--passphrase=${passphrase}")
        [[ ${#app_args[@]} -gt 0 ]] && remote_cmd+=("${app_args[@]}")

        step "Running: ${remote_cmd[*]}"
        echo ""
        ssh -t ${ssh_opts} "${remote_user}@${remote_host}" "${remote_cmd[*]}"
        local rc=$?
        echo ""
        if [[ $rc -eq 0 ]]; then
            success "Remote import completed"
        else
            warn "Remote import exited with code ${rc}"
            echo -e "  ${DIM}You can retry manually on the remote:${NC}"
            echo -e "  ${CYAN}ssh -p ${remote_port} ${remote_user}@${remote_host}${NC}"
            echo -e "  ${CYAN}cipi sync import /tmp/${archive_name}${NC}"
        fi
    else
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "  ${GREEN}${BOLD}PUSH COMPLETE${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo -e "  Archive:  ${CYAN}/tmp/${archive_name}${NC} on ${CYAN}${remote_host}${NC}"
        echo ""
        echo -e "  ${BOLD}Next: SSH into the target and import${NC}"
        echo -e "  ${CYAN}ssh -p ${remote_port} ${remote_user}@${remote_host}${NC}"
        echo -e "  ${CYAN}cipi sync list /tmp/${archive_name}${NC}"
        echo -e "  ${CYAN}cipi sync import /tmp/${archive_name}${NC}"
        echo ""
        echo -e "  ${DIM}Or re-run with --import to auto-import:${NC}"
        echo -e "  ${CYAN}cipi sync push ${app_args[*]} --host=${remote_host} --port=${remote_port} --import${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    fi

    log_action "SYNC PUSH: → ${remote_user}@${remote_host}:${remote_port} import=${remote_import}"
    cipi_notify \
        "Cipi sync push on $(hostname)" \
        "Apps were pushed to a remote server.\n\nServer: $(hostname)\nRemote: ${remote_user}@${remote_host}:${remote_port}\nImport on remote: ${remote_import}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        sync_push
}

# ── PUBKEY (show this server's sync public key) ──────────────

_sync_pubkey() {
    local keyfile="/home/cipi/.ssh/id_ed25519.pub"
    if [[ ! -f "$keyfile" ]]; then
        error "Server sync key not found at ${keyfile}"
        echo -e "  ${DIM}Re-run setup or generate manually:${NC}"
        echo -e "  ${CYAN}sudo -u cipi ssh-keygen -t ed25519 -C \"cipi@\$(hostname)\" -f /home/cipi/.ssh/id_ed25519 -N \"\"${NC}"
        exit 1
    fi

    echo ""
    echo -e "  ${BOLD}This server's sync public key:${NC}"
    echo ""
    echo -e "  ${CYAN}$(cat "$keyfile")${NC}"
    echo ""
    echo -e "  ${DIM}Add this key on the remote server with:${NC}"
    echo -e "  ${CYAN}cipi sync trust${NC}"
    echo ""
}

# ── TRUST (add a remote server's sync key to authorized_keys) ─

_sync_trust() {
    parse_args "$@"

    local keyfile="/home/cipi/.ssh/authorized_keys"
    local key="${ARG_key:-}"

    echo ""
    echo -e "  ${BOLD}Trust a Remote Server${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "  This adds a remote server's public key so it can"
    echo -e "  connect via ${CYAN}cipi sync push${NC} without a password."
    echo ""
    echo -e "  ${DIM}On the source server, run: cipi sync pubkey${NC}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [[ -z "$key" ]]; then
        echo -en "  ${BOLD}Paste the remote server's public key:${NC} "
        read -r key
    fi

    if [[ -z "$key" ]]; then
        error "No key provided"
        exit 1
    fi

    # Validate format
    if ! echo "$key" | grep -qE '^(ssh-(rsa|ed25519)|ecdsa-sha2-\S+) '; then
        error "Invalid key format. Must start with ssh-rsa, ssh-ed25519, or ecdsa-sha2-*"
        exit 1
    fi

    # Check for duplicates
    if grep -qF "$key" "$keyfile" 2>/dev/null; then
        warn "Key already trusted"
        exit 0
    fi

    # Append
    echo "$key" >> "$keyfile"
    chown cipi:cipi "$keyfile"
    chmod 600 "$keyfile"

    success "Key added to cipi's authorized_keys"
    echo ""
    echo -e "  ${DIM}The remote server can now run:${NC}"
    echo -e "  ${CYAN}cipi sync push <app> --host=$(curl -s --max-time 3 https://checkip.amazonaws.com 2>/dev/null || hostname)${NC}"
    echo ""

    log_action "SYNC TRUST: key added"
}
