#!/bin/bash
#############################################
# Cipi — Database Management (MariaDB + PostgreSQL)
#############################################

# Engines: mariadb (native, port 3306) and pgsql (optional, port 5432).
# Aliases accepted on CLI: postgres → pgsql, postgresql → pgsql, mysql → mariadb.
#
# The engine on port 3306 is MariaDB, or MySQL after `cipi db switch mysql`
# (db_mysql_flavor in common.sh). Its id stays "mariadb" everywhere it is
# stored, so apps, registries, backups and the panel are the same either way.

db_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        install)   _db_install_engine "$@" ;;
        uninstall|remove-engine) _db_uninstall_engine "$@" ;;
        default)   _db_set_default "$@" ;;
        engines)   _db_engines "$@" ;;
        switch)    _db_switch "$@" ;;
        upgrade)   source "${CIPI_LIB}/stack-upgrade.sh"; _stack_upgrade_db "$@" ;;
        create)    _db_create "$@" ;;
        list|ls)   _db_list "$@" ;;
        delete)    _db_delete "$@" ;;
        link)      _db_link "$@" ;;
        unlink)    _db_unlink "$@" ;;
        backup)    _db_backup "$@" ;;
        restore)   _db_restore "$@" ;;
        password)  _db_password "$@" ;;
        *) error "Use: install uninstall default engines switch create list delete link unlink backup restore password upgrade"; exit 1 ;;
    esac
}

# ── Engine helpers (also used by app/backup/sync) ─────────────

db_normalize_engine() {
    case "${1:-}" in
        mariadb|mysql) echo "mariadb" ;;
        pgsql|postgres|postgresql) echo "pgsql" ;;
        "") echo "" ;;
        *) return 1 ;;
    esac
}

db_engine_label() {
    case "${1:-}" in
        mariadb) db_mysql_label ;;
        pgsql)   echo "PostgreSQL" ;;
        *)       echo "${1:-unknown}" ;;
    esac
}

# The engine as a message names it: its id — what --engine= takes, and what
# the API reads in these messages — except on a server whose port 3306 runs
# MySQL (cipi db switch mysql). There the id is still "mariadb", and a line
# saying "Engine: mariadb" names a server that is not installed: the message
# says "mysql", which --engine= takes as well. Through the API (sudo as
# www-data) the id stays: its parser, and the ones of the releases already
# installed, expect "mariadb" or "pgsql". `always` is for texts nobody parses
# (notifications).
_db_engine_shown() {
    local e="${1:-}" always="${2:-}"
    if [[ "$e" == "mariadb" && "$(db_mysql_flavor 2>/dev/null)" == "mysql" ]] \
        && { [[ "$always" == "always" ]] || [[ "${SUDO_USER:-}" != "www-data" ]]; }; then
        echo "mysql"
    else
        echo "$e"
    fi
}

db_engine_port() {
    case "${1:-}" in
        mariadb) echo "3306" ;;
        pgsql)   echo "5432" ;;
        *)       echo "" ;;
    esac
}

db_engine_laravel_connection() {
    case "${1:-}" in
        mariadb) echo "mysql" ;;
        pgsql)   echo "pgsql" ;;
        *)       echo "" ;;
    esac
}

db_engine_service_name() {
    case "${1:-}" in
        mariadb) db_mysql_unit ;;
        pgsql)   echo "postgresql" ;;
        *)       echo "" ;;
    esac
}

# Ensure server.json has db_default_engine + db_engines.mariadb (idempotent).
db_ensure_engine_state() {
    local sj tmp
    sj=$(vault_read server.json 2>/dev/null) || sj="{}"
    if ! echo "$sj" | jq -e '.db_default_engine' &>/dev/null \
       || ! echo "$sj" | jq -e '.db_engines.mariadb' &>/dev/null; then
        tmp=$(mktemp)
        echo "$sj" | jq '
            .db_default_engine = (.db_default_engine // "mariadb")
            | .db_engines = (.db_engines // {})
            | .db_engines.mariadb = (.db_engines.mariadb // {installed: true, port: 3306})
            | .db_engines.mariadb.installed = true
            | .db_engines.mariadb.port = (.db_engines.mariadb.port // 3306)
        ' > "$tmp"
        vault_write server.json < "$tmp"
        rm -f "$tmp"
    fi
    _db_migrate_databases_json
}

# Migrate flat databases.json → { mariadb: { name: {...} }, pgsql: {...} }
_db_migrate_databases_json() {
    local meta tmp
    meta=$(vault_read databases.json 2>/dev/null) || meta="{}"
    [[ -z "$meta" || "$meta" == "null" ]] && meta="{}"
    # Already nested if top-level has only engine keys (or empty)
    if echo "$meta" | jq -e '
        type == "object" and (
            (keys | length) == 0
            or (keys - ["mariadb","pgsql"] | length) == 0
        )
    ' &>/dev/null; then
        return 0
    fi
    # Flat legacy: values look like {user, created_at}
    if echo "$meta" | jq -e '
        type == "object" and (keys | length) > 0
        and (to_entries | all(.value | type == "object" and has("user")))
    ' &>/dev/null; then
        tmp=$(mktemp)
        echo "$meta" | jq '{mariadb: ., pgsql: {}}' > "$tmp"
        vault_write databases.json < "$tmp"
        rm -f "$tmp"
    fi
}

db_get_default_engine() {
    db_ensure_engine_state
    vault_read server.json | jq -r '.db_default_engine // "mariadb"'
}

db_engine_is_installed() {
    local engine="$1"
    engine=$(db_normalize_engine "$engine") || return 1
    db_ensure_engine_state
    case "$engine" in
        mariadb)
            [[ "$(vault_read server.json | jq -r '.db_engines.mariadb.installed // true')" == "true" ]] \
                && systemd_unit_exists "$(db_mysql_unit)"
            ;;
        pgsql)
            [[ "$(vault_read server.json | jq -r '.db_engines.pgsql.installed // false')" == "true" ]] \
                && command -v psql &>/dev/null \
                && systemd_unit_exists postgresql
            ;;
        *) return 1 ;;
    esac
}

db_require_engine() {
    local engine="$1"
    engine=$(db_normalize_engine "$engine") || { error "Invalid engine. Use: mariadb pgsql"; return 1; }
    db_engine_is_installed "$engine" || {
        error "$(db_engine_label "$engine") is not installed. Run: cipi db install ${engine}"
        return 1
    }
    echo "$engine"
}

db_resolve_engine_arg() {
    # Usage: db_resolve_engine_arg [--engine=X]  → prints normalized engine
    local raw="${ARG_engine:-}"
    local engine
    if [[ -n "$raw" ]]; then
        engine=$(db_normalize_engine "$raw") || { error "Invalid --engine=${raw}. Use: mariadb pgsql"; return 1; }
    else
        engine=$(db_get_default_engine)
    fi
    db_require_engine "$engine"
}

db_get_root_password() {
    local engine="${1:-}"
    engine=$(db_normalize_engine "$engine") || return 1
    case "$engine" in
        mariadb) vault_read server.json | jq -r '.db_root_password // empty' ;;
        pgsql)   vault_read server.json | jq -r '.db_engines.pgsql.root_password // .pgsql_root_password // empty' ;;
    esac
}

# Resolve which engine owns a named DB (registry / apps).
# Returns 0 + engine, 1 if unknown, 2 if ambiguous (same name on multiple engines).
db_lookup_engine_for_name() {
    local name="$1"
    local prefer="${2:-}" # optional preferred engine
    db_ensure_engine_state
    local meta
    meta=$(vault_read databases.json 2>/dev/null) || meta="{}"
    if [[ -n "$prefer" ]]; then
        prefer=$(db_normalize_engine "$prefer" 2>/dev/null || true)
        if [[ -n "$prefer" ]] && echo "$meta" | jq -e --arg e "$prefer" --arg n "$name" '.[$e][$n]' &>/dev/null; then
            echo "$prefer"
            return 0
        fi
    fi
    local found="" e
    for e in mariadb pgsql; do
        if echo "$meta" | jq -e --arg e "$e" --arg n "$name" '.[$e][$n]' &>/dev/null; then
            if [[ -n "$found" && "$found" != "$e" ]]; then
                echo ""
                return 2
            fi
            found="$e"
        fi
    done
    # Also check apps.json (app name == db name)
    if [[ -z "$found" ]] && [[ -f "${CIPI_CONFIG}/apps.json" ]]; then
        local app_engine
        app_engine=$(vault_read apps.json | jq -r --arg n "$name" '.[$n].engine // empty' 2>/dev/null)
        if [[ -n "$app_engine" ]]; then
            found=$(db_normalize_engine "$app_engine" 2>/dev/null || true)
        elif vault_read apps.json | jq -e --arg n "$name" '.[$n] and ((.[$n].custom // false) | not)' &>/dev/null; then
            found="mariadb"
        fi
    fi
    [[ -n "$found" ]] || return 1
    echo "$found"
    return 0
}

_db_meta_set() {
    local engine="$1" name="$2" user="$3"
    db_ensure_engine_state
    vault_read databases.json | \
        jq --arg e "$engine" --arg n "$name" --arg u "$user" '
            .[$e] = (.[$e] // {})
            | .[$e][$n] = {"user":$u,"created_at":(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}
        ' | vault_write databases.json
}

_db_meta_del() {
    local engine="$1" name="$2"
    db_ensure_engine_state
    vault_read databases.json | jq --arg e "$engine" --arg n "$name" 'del(.[$e][$n])' | vault_write databases.json
}

_db_meta_user() {
    local engine="$1" name="$2"
    vault_read databases.json | jq -r --arg e "$engine" --arg n "$name" '.[$e][$n].user // $n' 2>/dev/null
}

# ── Databases linked to an app ───────────────────────────────
#
# `cipi db create` makes a database that belongs to nobody: the WordPress of
# a custom app has one, and nothing on the server or in the panel says so. A
# link is one line in the app's entry of apps.json —
#     "databases": [{"name": "wpblog", "engine": "mariadb"}]
# — so it is in the projection the panel reads, travels with the app
# (cipi sync) and is gone with it when the app is deleted. A database is
# linked to one app at most. The link grants nothing: the database keeps its
# own user and password, and deleting the app leaves it where it is.
#
# Without a link a database still has an owner Cipi already knows: the one
# created with a Laravel app has the app's name ("own"), and cipi.yml lets an
# app declare databases named <app>_… ("namespace").

# Every explicit link, "<app>\t<engine>\t<name>" per line.
_db_links() {
    vault_read apps.json 2>/dev/null | jq -r '
        to_entries[] | .key as $a | (.value.databases // [])[]
        | select((.name // "") != "") | [$a, (.engine // "mariadb"), .name] | @tsv' 2>/dev/null || true
}

# The app a database is linked to (an explicit link only); nothing when none.
db_linked_app() {   # <engine> <name>
    _db_links | awk -F'\t' -v e="$1" -v n="$2" '$2 == e && $3 == n { print $1; exit }'
}

_db_link_del() {   # <engine> <name>
    [[ -f "${CIPI_CONFIG}/apps.json" ]] || return 0
    local cur; cur=$(vault_read apps.json) || return 0
    jq -e --arg e "$1" --arg n "$2" 'any(.[]; (.databases // []) | any(.name == $n and (.engine // "mariadb") == $e))' <<< "$cur" &>/dev/null || return 0
    jq --arg e "$1" --arg n "$2" '
        with_entries(if (.value | has("databases")) then
            .value.databases |= map(select((.name == $n and (.engine // "mariadb") == $e) | not))
            | if (.value.databases | length) == 0 then .value |= del(.databases) else . end
        else . end)' <<< "$cur" | vault_write apps.json
    ensure_apps_json_api_access
}

_db_link_set() {   # <app> <engine> <name>
    _db_link_del "$2" "$3"
    vault_read apps.json | jq --arg a "$1" --arg e "$2" --arg n "$3" '
        .[$a].databases = (((.[$a].databases // []) + [{name: $n, engine: $e}]) | sort_by(.engine, .name))
    ' | vault_write apps.json
    ensure_apps_json_api_access
}

# cipi db link <database> <app> [--engine=]
_db_link() {
    local name="${1:-}" app="${2:-}"
    [[ -z "$name" || -z "$app" || "$name" == --* || "$app" == --* ]] && { error "Usage: cipi db link <database> <app> [--engine=]"; exit 1; }
    validate_db_name "$name" || { error "Invalid name"; exit 1; }
    app_exists "$app" || { error "App '${app}' not found"; exit 1; }
    parse_args "$@"
    local RESOLVED_ENGINE=""
    _db_resolve_name_engine "$name" || exit 1
    local engine="$RESOLVED_ENGINE"
    local have; have=$(db_list_databases "$engine" 2>/dev/null || true)
    grep -qx -- "$name" <<< "$have" || { error "No database '${name}' on $(_db_engine_shown "$engine")"; exit 1; }
    local own_engine; own_engine=$(app_get "$app" engine); [[ -z "$own_engine" ]] && own_engine="mariadb"
    if [[ "$name" == "$app" && "$(app_get "$app" custom)" != "true" && "$(db_normalize_engine "$own_engine" 2>/dev/null || echo mariadb)" == "$engine" ]]; then
        info "'${name}' is the database created with '${app}' — it is already shown as its own"
        return 0
    fi
    local was; was=$(db_linked_app "$engine" "$name")
    if [[ "$was" == "$app" ]]; then
        info "'${name}' ($(_db_engine_shown "$engine")) is already linked to '${app}'"
        return 0
    fi
    _db_link_set "$app" "$engine" "$name"
    log_action "DB LINKED: $name ($engine) -> $app${was:+ (was $was)}"
    success "'${name}' ($(_db_engine_shown "$engine")) linked to app '${app}'${was:+ — it was linked to '${was}'}"
    echo -e "  ${DIM}Only a label: the database keeps its user and password, and stays when the app is deleted.${NC}"
}

# cipi db unlink <database> [--engine=]
_db_unlink() {
    local name="${1:-}"
    [[ -z "$name" || "$name" == --* ]] && { error "Usage: cipi db unlink <database> [--engine=]"; exit 1; }
    validate_db_name "$name" || { error "Invalid name"; exit 1; }
    parse_args "$@"
    local RESOLVED_ENGINE=""
    _db_resolve_name_engine "$name" || exit 1
    local engine="$RESOLVED_ENGINE" was
    was=$(db_linked_app "$engine" "$name")
    [[ -n "$was" ]] || { info "'${name}' ($(_db_engine_shown "$engine")) is not linked to an app"; return 0; }
    _db_link_del "$engine" "$name"
    log_action "DB UNLINKED: $name ($engine) from $was"
    success "'${name}' ($(_db_engine_shown "$engine")) unlinked from app '${was}'"
}

# ── Low-level SQL ops ────────────────────────────────────────

_db_mariadb_exec() {
    local dbr; dbr=$(db_get_root_password mariadb)
    [[ -z "$dbr" || "$dbr" == "null" ]] && { error "$(db_mysql_label) root password not configured (reset with: cipi reset db-password)"; return 1; }
    "$(db_mysql_client)" -u root -p"$dbr" "$@"
}

_db_pgsql_exec() {
    local dbr; dbr=$(db_get_root_password pgsql)
    [[ -z "$dbr" || "$dbr" == "null" ]] && { error "PostgreSQL password not configured. Reinstall with: cipi db install pgsql"; return 1; }
    PGPASSWORD="$dbr" psql -U postgres -h 127.0.0.1 -p 5432 -v ON_ERROR_STOP=1 "$@"
}

db_create_database() {
    local engine="$1" name="$2" user="$3" pass="$4"
    case "$engine" in
        mariadb)
            _db_mariadb_exec <<SQL
CREATE DATABASE IF NOT EXISTS \`${name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${user}'@'localhost' IDENTIFIED BY '${pass}';
CREATE USER IF NOT EXISTS '${user}'@'127.0.0.1' IDENTIFIED BY '${pass}';
GRANT ALL PRIVILEGES ON \`${name}\`.* TO '${user}'@'localhost';
GRANT ALL PRIVILEGES ON \`${name}\`.* TO '${user}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
            ;;
        pgsql)
            # CREATE USER / DATABASE are not IF NOT EXISTS on older PG — check first
            if _db_pgsql_exec -tAc "SELECT 1 FROM pg_roles WHERE rolname='${user}'" | grep -q 1; then
                _db_pgsql_exec -c "ALTER USER \"${user}\" WITH PASSWORD '${pass}';"
            else
                _db_pgsql_exec -c "CREATE USER \"${user}\" WITH PASSWORD '${pass}';"
            fi
            if ! _db_pgsql_exec -tAc "SELECT 1 FROM pg_database WHERE datname='${name}'" | grep -q 1; then
                _db_pgsql_exec -c "CREATE DATABASE \"${name}\" OWNER \"${user}\" ENCODING 'UTF8' TEMPLATE template0;"
            else
                _db_pgsql_exec -c "ALTER DATABASE \"${name}\" OWNER TO \"${user}\";"
            fi
            _db_pgsql_exec -d "$name" -c "GRANT ALL ON SCHEMA public TO \"${user}\"; ALTER SCHEMA public OWNER TO \"${user}\";"
            ;;
        *) return 1 ;;
    esac
}

db_drop_database() {
    local engine="$1" name="$2" user="${3:-$2}"
    case "$engine" in
        mariadb)
            _db_mariadb_exec -e "DROP DATABASE IF EXISTS \`${name}\`; DROP USER IF EXISTS '${user}'@'localhost'; DROP USER IF EXISTS '${user}'@'127.0.0.1'; FLUSH PRIVILEGES;" 2>/dev/null || true
            ;;
        pgsql)
            _db_pgsql_exec -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${name}' AND pid <> pg_backend_pid();" 2>/dev/null || true
            _db_pgsql_exec -c "DROP DATABASE IF EXISTS \"${name}\";" 2>/dev/null || true
            _db_pgsql_exec -c "DROP USER IF EXISTS \"${user}\";" 2>/dev/null || true
            ;;
        *) return 1 ;;
    esac
}

db_change_user_password() {
    local engine="$1" user="$2" pass="$3"
    case "$engine" in
        mariadb)
            _db_mariadb_exec <<SQL
ALTER USER '${user}'@'localhost' IDENTIFIED BY '${pass}';
ALTER USER '${user}'@'127.0.0.1' IDENTIFIED BY '${pass}';
FLUSH PRIVILEGES;
SQL
            ;;
        pgsql)
            _db_pgsql_exec -c "ALTER USER \"${user}\" WITH PASSWORD '${pass}';"
            ;;
        *) return 1 ;;
    esac
}

db_dump_database() {
    local engine="$1" name="$2" outfile="$3"
    case "$engine" in
        mariadb)
            local dbr; dbr=$(db_get_root_password mariadb)
            mysqldump -u root -p"$dbr" --single-transaction --routines --triggers "$name" 2>/dev/null | gzip >"$outfile"
            ;;
        pgsql)
            local dbr; dbr=$(db_get_root_password pgsql)
            PGPASSWORD="$dbr" pg_dump -U postgres -h 127.0.0.1 -p 5432 --no-owner --no-acl "$name" 2>/dev/null | gzip >"$outfile"
            ;;
        *) return 1 ;;
    esac
    [[ -s "$outfile" ]]
}

# ── Discovery (live engine state, not the registry) ──────────
#
# databases.json only knows about databases created through `cipi db create`.
# A multi-tenant app creates its tenant databases at runtime, so the registry
# can never list them — and a backup driven by the registry silently skips
# every tenant. These helpers ask the engine what actually exists, minus the
# engine's own system schemas.

db_system_schemas() {
    case "$1" in
        mariadb) echo "information_schema mysql performance_schema sys" ;;
        pgsql)   echo "postgres template0 template1" ;;
    esac
}

# Print one database name per line for an installed engine.
db_list_databases() {
    local engine="$1"
    engine=$(db_normalize_engine "$engine") || return 1
    case "$engine" in
        mariadb)
            local dbr; dbr=$(db_get_root_password mariadb)
            [[ -z "$dbr" || "$dbr" == "null" ]] && return 1
            "$(db_mysql_client)" -u root -p"$dbr" -N -B -e \
                "SELECT schema_name FROM information_schema.schemata
                 WHERE schema_name NOT IN ('information_schema','mysql','performance_schema','sys')
                 ORDER BY schema_name;" 2>/dev/null
            ;;
        pgsql)
            _db_pgsql_exec -tAc \
                "SELECT datname FROM pg_database
                 WHERE datistemplate = false AND datname NOT IN ('postgres')
                 ORDER BY datname;" 2>/dev/null | sed 's/[[:space:]]*$//' | grep -v '^$'
            ;;
        *) return 1 ;;
    esac
}

# True when the named database exists on the engine.
db_database_exists() {
    local engine="$1" name="$2"
    db_list_databases "$engine" 2>/dev/null | grep -qx "$name"
}

# Print one table name per line.
db_list_tables() {
    local engine="$1" name="$2"
    case "$engine" in
        mariadb)
            local dbr; dbr=$(db_get_root_password mariadb)
            [[ -z "$dbr" || "$dbr" == "null" ]] && return 1
            "$(db_mysql_client)" -u root -p"$dbr" -N -B -e \
                "SELECT table_name FROM information_schema.tables
                 WHERE table_schema = '${name}' AND table_type = 'BASE TABLE'
                 ORDER BY table_name;" 2>/dev/null
            ;;
        pgsql)
            _db_pgsql_exec -d "$name" -tAc \
                "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;" 2>/dev/null \
                | sed 's/[[:space:]]*$//' | grep -v '^$'
            ;;
        *) return 1 ;;
    esac
}

# Dump with optional table exclusions.
#
# `excludes` is a comma-separated list of glob patterns, each either
# "<db-glob>.<table-glob>" or a bare "<table-glob>" (any database). Excluding
# high-churn tables (jobs, telescope_*, *_logs) is what makes a 30-minute
# database backup affordable next to a slower full one.
#
# MariaDB's --ignore-table takes literal db.table names only, so the patterns
# are expanded against the live table list first. pg_dump takes globs directly.
db_dump_database_ex() {
    local engine="$1" name="$2" outfile="$3" excludes="${4:-}"

    [[ -z "$excludes" ]] && { db_dump_database "$engine" "$name" "$outfile"; return $?; }

    case "$engine" in
        mariadb)
            local dbr; dbr=$(db_get_root_password mariadb)
            local -a ignore=()
            local table pat db_glob tbl_glob
            while IFS= read -r table; do
                [[ -n "$table" ]] || continue
                while IFS=',' read -ra _pats; do
                    for pat in "${_pats[@]}"; do
                        pat="${pat#"${pat%%[![:space:]]*}"}"; pat="${pat%"${pat##*[![:space:]]}"}"
                        [[ -n "$pat" ]] || continue
                        if [[ "$pat" == *.* ]]; then
                            db_glob="${pat%%.*}"; tbl_glob="${pat#*.}"
                        else
                            db_glob="*"; tbl_glob="$pat"
                        fi
                        # shellcheck disable=SC2053
                        if [[ "$name" == $db_glob && "$table" == $tbl_glob ]]; then
                            ignore+=( "--ignore-table=${name}.${table}" )
                        fi
                    done
                done <<< "$excludes"
            done < <(db_list_tables mariadb "$name")
            mysqldump -u root -p"$dbr" --single-transaction --routines --triggers \
                "${ignore[@]}" "$name" 2>/dev/null | gzip >"$outfile"
            ;;
        pgsql)
            local dbr; dbr=$(db_get_root_password pgsql)
            local -a excl=()
            local pat
            while IFS=',' read -ra _pats; do
                for pat in "${_pats[@]}"; do
                    pat="${pat#"${pat%%[![:space:]]*}"}"; pat="${pat%"${pat##*[![:space:]]}"}"
                    [[ -n "$pat" ]] || continue
                    [[ "$pat" == *.* ]] && pat="${pat#*.}"
                    excl+=( "--exclude-table=${pat}" )
                done
            done <<< "$excludes"
            PGPASSWORD="$dbr" pg_dump -U postgres -h 127.0.0.1 -p 5432 --no-owner --no-acl \
                "${excl[@]}" "$name" 2>/dev/null | gzip >"$outfile"
            ;;
        *) return 1 ;;
    esac
    [[ -s "$outfile" ]]
}

# The dump as a stream, however it is stored. With a second argument the
# file is opened by that user instead of root (db_dump_reader).
_db_dump_cat() {   # <file> [user]
    if [[ -n "${2:-}" ]]; then
        if [[ "$1" == *.gz ]]; then app_as "$2" gunzip -c -- "$1" < /dev/null
        else app_as "$2" cat -- "$1" < /dev/null; fi
        return
    fi
    if [[ "$1" == *.gz ]]; then gunzip -c "$1"; else cat "$1"; fi
}

# Who opens a dump root is asked to restore. A file in an app's home, or in
# a tree of the panel (the API keeps the dumps uploaded through it in its own
# storage), is whatever that user made of the name a moment ago — a symlink
# to a file only root reads, for one. Root opening it would lend its rights
# to the import, and the first line the client cannot parse comes back in
# the error. So the owner of the tree opens it: the rule of app_as in
# common.sh. Prints the user, or nothing for a file that is root's to read.
db_dump_reader() {   # <file>
    local f="${1:-}" o
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || return 0
    declare -f app_of_path >/dev/null 2>&1 || return 0
    if o=$(app_of_path "$f"); then printf '%s' "$o"; return 0; fi
    if _panel_tree_is_www "$f"; then printf '%s' "www-data"; return 0; fi
    return 0
}

# psql stops at the first failed statement (ON_ERROR_STOP), so the preamble of
# a dump taken on a newer PostgreSQL must not trip it: pg_dump 17 writes
# `SET transaction_timeout = 0;`, which PostgreSQL 16 (Ubuntu 24.04) refuses as
# an unknown parameter. Such a dump arrives with `cipi sync` from a newer server
# or with `cipi db restore` of a file made elsewhere. The preamble's SET lines
# whose parameter this server does not have are dropped. Nothing past the
# preamble is touched, so a COPY data line that happens to start with "SET "
# goes through as is. When the settings cannot be read the dump passes unchanged.
#
# A dump that holds nothing is refused (exit 1, "the dump is empty"): a backup
# taken while pg_dump failed is a valid archive of nothing, since
# db_dump_database sends pg_dump's errors to /dev/null and gzips what is left,
# and the file's size cannot tell it from a real dump. The restore commits only
# after this filter has passed the whole stream, so such a file never commits a
# bare wipe. The check is on the stream, in the same pass: the file is read once.
_db_pgsql_restore_filter() {
    local dbr="$1" known
    # One line, space-separated: BSD awk refuses a newline in a -v value.
    known=$(PGPASSWORD="$dbr" psql -U postgres -h 127.0.0.1 -p 5432 -d postgres -tAc \
        "SELECT name FROM pg_settings" 2>/dev/null | tr '\n' ' ')
    awk -v known="$known" '
        BEGIN { n = split(known, k, " "); c = 0; for (i = 1; i <= n; i++) if (k[i] != "") { have[k[i]] = 1; c++ }; pre = (c > 0) }
        /[^[:space:]]/ { seen = 1 }
        pre && /^SET [A-Za-z_.]+ = / { if (!($2 in have)) next; print; next }
        pre && (/^$/ || /^--/ || /^\\(un)?restrict/ || /^SELECT pg_catalog\.set_config\(/) { print; next }
        { pre = 0; print }
        END { if (!seen) { print "the dump is empty" > "/dev/stderr"; exit 1 } }
    '
}

# The first error the client printed, so "Restore failed" says what to fix.
# BSD gzip reports as "gunzip:", GNU as "gzip:" whatever name it was run by.
_db_restore_say_why() {
    local engine="$1" errf="$2" line
    line=$(grep -m1 -E 'ERROR|FATAL|error:|g(un)?zip:' "$errf" 2>/dev/null | tr -s ' ')
    [[ -n "$line" ]] || line=$(grep -v '^[[:space:]]*$' "$errf" 2>/dev/null | tail -1)
    [[ -n "$line" ]] && error "$(db_engine_label "$engine") restore: ${line}"
    return 0
}

# A dump made by the other server of port 3306, made readable by this one:
# what moves an app between a MariaDB and a MySQL server (cipi sync, a
# backup restored on a server that was switched). Only the lines that are not
# rows of data are touched — mysqldump writes each INSERT on a line of its
# own, its strings with \n escaped — so a row that mentions a collation is
# imported as it is.
#   into MySQL:   MariaDB's sandbox line (/*M!999999\- enable the sandbox
#                 mode */, which the mysql client refuses) goes; its UCA 14
#                 collations, which MySQL does not have, become their 0900
#                 equivalents (utf8mb3 ones: utf8mb3_unicode_ci).
#   into MariaDB: MySQL's 0900 collations become the UCA 14 ones.
# What has no equivalent (MariaDB's uuid/inet6 types, sequences) is left as it
# is, and the import stops there with the server's own message.
_db_mysql_restore_filter() {   # <flavor of this server>  stdin → stdout
    if [[ "${1:-mariadb}" == "mysql" ]]; then
        sed -E \
            -e '1{/^\/\*M!999999\\- enable the sandbox mode \*\/[[:space:]]*$/d}' \
            -e '/^INSERT INTO /!{
                  s/\butf8mb4_uca1400_(nopad_)?ai_ci\b/utf8mb4_0900_ai_ci/g
                  s/\butf8mb4_uca1400_(nopad_)?as_ci\b/utf8mb4_0900_as_ci/g
                  s/\butf8mb4_uca1400_(nopad_)?(as|ai)_cs\b/utf8mb4_0900_as_cs/g
                  s/\butf8mb4_uca1400_(nopad_)?bin\b/utf8mb4_0900_bin/g
                  s/\butf8mb3_uca1400_[a-z_]*_c[is]\b/utf8mb3_unicode_ci/g
                }'
    else
        sed -E \
            -e '/^INSERT INTO /!{
                  s/\butf8mb4_0900_ai_ci\b/utf8mb4_uca1400_ai_ci/g
                  s/\butf8mb4_0900_as_ci\b/utf8mb4_uca1400_as_ci/g
                  s/\butf8mb4_0900_as_cs\b/utf8mb4_uca1400_as_cs/g
                  s/\butf8mb4_0900_bin\b/utf8mb4_bin/g
                }'
    fi
}

# Restore a dump into an existing database. Returns non-zero when the import
# did not complete, and says why. Both clients stop at the first failed
# statement (mariadb by default, psql through ON_ERROR_STOP=1), so a dump that
# cannot be imported is reported instead of leaving an empty database behind a
# success message. The pipelines run with pipefail of their own: a dump that
# does not even uncompress must not count as restored either.
db_restore_database() {
    local engine="$1" name="$2" file="$3"
    local err rc=0 reader=""
    reader=$(db_dump_reader "$file")
    err=$(mktemp) || return 1
    case "$engine" in
        mariadb)
            local dbr cli flavor; dbr=$(db_get_root_password mariadb); cli=$(db_mysql_client); flavor=$(db_mysql_flavor)
            ( set -o pipefail
              _db_dump_cat "$file" "$reader" 2>>"$err" \
                | _db_mysql_restore_filter "$flavor" 2>>"$err" \
                | "$cli" -u root -p"$dbr" "$name" >/dev/null 2>>"$err" ) || rc=$?
            ;;
        pgsql)
            local dbr; dbr=$(db_get_root_password pgsql)
            # The public schema is wiped before the import (parity with
            # drop/reimport). Wipe and import run in one transaction, and COMMIT
            # is sent only once the whole dump has been read: a failed statement
            # or a dump that breaks off (truncated .gz, read error) closes the
            # session without it, so the wipe is rolled back and the database
            # stays as it was. A dump that holds nothing would commit a bare
            # wipe: the filter refuses it, so no COMMIT follows it either.
            # The new schema goes to the database's owner, which is not named
            # after the database when it was created with --user.
            ( set -o pipefail
              { printf '%s\n' "BEGIN;" "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" \
                    "DO \$\$ BEGIN EXECUTE format('ALTER SCHEMA public OWNER TO %I', (SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database())); END \$\$;"
                _db_dump_cat "$file" "$reader" 2>>"$err" | _db_pgsql_restore_filter "$dbr" 2>>"$err" && printf '%s\n' "COMMIT;"
              } | PGPASSWORD="$dbr" psql -U postgres -h 127.0.0.1 -p 5432 -d "$name" -v ON_ERROR_STOP=1 >/dev/null 2>>"$err" ) || rc=$?
            ;;
        *) rm -f "${err:?}"; return 1 ;;
    esac
    if (( rc != 0 )); then _db_restore_say_why "$engine" "$err"; fi
    rm -f "${err:?}"
    return "$rc"
}

db_laravel_env_block() {
    local engine="$1" name="$2" user="$3" pass="$4"
    local conn port
    conn=$(db_engine_laravel_connection "$engine")
    port=$(db_engine_port "$engine")
    cat <<ENV
DB_CONNECTION=${conn}
DB_HOST=127.0.0.1
DB_PORT=${port}
DB_DATABASE=${name}
DB_USERNAME=${user}
DB_PASSWORD=${pass}
ENV
}

db_connection_url() {
    # TablePlus-style SSH tunnel URL
    local engine="$1" ssh_user="$2" ssh_pass="$3" server_ip="$4" db_user="$5" db_pass="$6" db_name="$7"
    local port host="127.0.0.1"
    port=$(db_engine_port "$engine")
    case "$engine" in
        mariadb)
            # mysql+ssh:// where `cipi db switch mysql` ran, as in cipi credentials.
            echo "$(db_mysql_flavor)+ssh://${ssh_user}:${ssh_pass}@${server_ip}/${db_user}:${db_pass}@${host}/${db_name}"
            ;;
        pgsql)
            echo "postgresql+ssh://${ssh_user}:${ssh_pass}@${server_ip}/${db_user}:${db_pass}@${host}:${port}/${db_name}"
            ;;
    esac
}

# ── Install / uninstall / default ─────────────────────────────

_db_install_engine() {
    local raw="${1:-}"
    [[ -z "$raw" ]] && { error "Usage: cipi db install <mariadb|mysql|pgsql>"; exit 1; }
    local engine
    engine=$(db_normalize_engine "$raw") || { error "Invalid engine '${raw}'. Use: mariadb mysql pgsql"; exit 1; }
    db_ensure_engine_state

    case "$engine" in
        mariadb)
            # Which server port 3306 runs is chosen by `cipi db switch`, from
            # the command line only: `install` (which the panel may run)
            # installs the one chosen, never the other.
            local want="" have; have=$(db_mysql_flavor)
            [[ "$raw" == "mysql" || "$raw" == "mariadb" ]] && want="$raw"
            if [[ -n "$want" && "$want" != "$have" ]]; then
                if db_engine_is_installed mariadb; then
                    info "$(db_mysql_label) is installed on port 3306"
                    echo -e "  To replace it (a server with no databases on it): ${CYAN}cipi db switch ${want}${NC}"
                else
                    error "Port 3306 is set to run $(db_mysql_label). To choose $(_db_server_label "$want"): cipi db switch ${want}"
                    exit 1
                fi
                return 0
            fi
            _db_install_mariadb
            ;;
        pgsql)   _db_install_pgsql ;;
    esac
}

_db_install_mariadb() {
    local flavor label; flavor=$(db_mysql_flavor); label=$(db_mysql_label)
    if db_engine_is_installed mariadb; then
        info "${label} is already installed"
        return 0
    fi
    step "Installing ${label}..."
    local pass; pass=$(generate_password 40)
    _db_server_install "$flavor" "$pass" || { error "${label} install failed"; exit 1; }
    _db_switch_record "$flavor" true "$pass"
    log_action "DB ENGINE INSTALLED: mariadb (${flavor})"
    success "${label} installed on port 3306"
    echo -e "${YELLOW}Root password saved in vault. Reset with: cipi reset db-password --engine=mariadb${NC}"
}

# ── MariaDB or MySQL on port 3306 ────────────────────────────
#
# `cipi db switch mysql` replaces MariaDB with MySQL, and `switch mariadb`
# puts it back. Only on a server with no databases on port 3306: the data is
# not converted (no in-place upgrade exists between the two, and what a dump
# cannot carry — MariaDB's uuid/inet6 types, sequences, queries an app sends
# that only one of them understands — would surface later, in the apps). A
# server in use moves to MySQL the way an app moves anywhere: a new server
# switched before its first app, then `cipi sync`, whose import makes the
# MariaDB dumps readable by MySQL (_db_mysql_restore_filter); the old server
# is the way back. Never offered to the panel: CLI only, and --yes when no
# terminal can confirm it.
#
# MySQL comes from the Ubuntu archive (8.0 on 24.04, where Ubuntu backports
# its security fixes; 8.4 LTS on 26.04): no repository or key of its own.

_db_apt() { DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 "$@"; }

# The version apt would install, empty when none. apt's output is read whole:
# with `| awk '…{print; exit}'` gawk — the awk of Ubuntu Server, through
# byobu — stops reading at the first match, apt-cache dies of SIGPIPE on its
# next line, and under pipefail set -e ended `cipi db switch` right after
# "Checking the MySQL packages..." with nothing said (5.13.0).
_db_apt_candidate() {   # <package>
    local out
    out=$(LC_ALL=C apt-cache policy "$1" 2>/dev/null) || true
    awk '/^[[:space:]]*Candidate:/ && !f { print $2; f = 1 }' <<< "$out"
}

_db_mysql_etc()  { echo "${DB_MYSQL_ETC:-/etc/mysql}"; }
_db_mysql_data() { echo "${DB_MYSQL_DATA:-/var/lib/mysql}"; }
_db_server_cnf() {   # <flavor> — Cipi's tuning for that server
    if [[ "$1" == "mysql" ]]; then echo "$(_db_mysql_etc)/mysql.conf.d/99-cipi.cnf"
    else echo "$(_db_mysql_etc)/mariadb.conf.d/99-cipi.cnf"; fi
}
_db_server_unit()  { [[ "$1" == "mysql" ]] && echo mysql || echo mariadb; }
_db_server_label() { [[ "$1" == "mysql" ]] && echo MySQL || echo MariaDB; }
_db_server_client() { [[ "$1" == "mysql" ]] && echo mysql || echo mariadb; }
_db_server_install_pkgs() { [[ "$1" == "mysql" ]] && echo "mysql-server mysql-client" || echo "mariadb-server mariadb-client"; }

# Installed packages of one server. The client libraries other software links
# (libmariadb3, libmysqlclient*) are not on the list; mysql-common is, so the
# one that comes back is the one of the next server (MariaDB.org ships its own).
_db_server_pkgs() {   # <flavor>
    local pat='^(mariadb-|galera-|mysql-common$)'
    [[ "$1" == "mysql" ]] && pat='^mysql-'
    dpkg-query -W -f='${db:Status-Status} ${Package}\n' 2>/dev/null \
        | awk -v p="$pat" '$1 == "installed" && $2 ~ p { print $2 }'
}

# The tuning setup.sh gives MariaDB, for either server.
_db_server_write_cnf() {   # <flavor>
    local f bp="256M" ram
    f=$(_db_server_cnf "$1")
    ram=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}'); [[ "$ram" =~ ^[0-9]+$ ]] || ram=1024
    (( ram >= 2048 ))  && bp="512M"
    (( ram >= 4096 ))  && bp="1G"
    (( ram >= 8192 ))  && bp="2G"
    (( ram >= 16384 )) && bp="4G"
    mkdir -p "$(dirname "$f")"
    if [[ "$1" == "mysql" ]]; then
        # innodb_redo_log_capacity: what innodb_log_file_size became (8.0.30).
        cat > "$f" <<CNFEOF
[mysqld]
bind-address = 127.0.0.1
mysqlx-bind-address = 127.0.0.1
innodb_buffer_pool_size = ${bp}
innodb_redo_log_capacity = 256M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
max_connections = 100
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
skip-name-resolve
CNFEOF
    else
        cat > "$f" <<CNFEOF
[mysqld]
bind-address = 127.0.0.1
innodb_buffer_pool_size = ${bp}
innodb_log_file_size = 256M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
max_connections = 100
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
skip-name-resolve
CNFEOF
    fi
}

# Packages, root password (the socket of a fresh install lets root in once),
# tuning, a running unit that answers with the password. 0 or 1.
_db_server_install() {   # <flavor> <root password>
    local flavor="$1" pass="$2" cli unit
    cli=$(_db_server_client "$flavor"); unit=$(_db_server_unit "$flavor")
    if [[ "$flavor" == "mariadb" ]]; then
        # shellcheck source=/dev/null
        source "${CIPI_LIB}/php-apt.sh"
        mariadb_setup_apt_repo || true
    fi
    _db_apt update -qq >/dev/null 2>&1 || true
    # shellcheck disable=SC2046
    _db_apt install -y -qq $(_db_server_install_pkgs "$flavor") || return 1
    local auth="IDENTIFIED BY"
    [[ "$flavor" == "mysql" ]] && auth="IDENTIFIED WITH caching_sha2_password BY"
    "$cli" -u root <<SQL || return 1
ALTER USER 'root'@'localhost' ${auth} '${pass}';
DROP USER IF EXISTS ''@'localhost';
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
SQL
    _db_server_write_cnf "$flavor" || return 1
    systemctl enable "$unit" >/dev/null 2>&1 || true
    systemctl restart "$unit" || return 1
    "$cli" -u root -p"$pass" -N -e "SELECT VERSION();" >/dev/null 2>&1
}

# server.json: which server runs on port 3306, and whether it is installed.
_db_switch_record() {   # <flavor> <installed true|false> [root password]
    local tmp; tmp=$(mktemp)
    vault_read server.json | jq --arg f "$1" --argjson i "$2" --arg p "${3:-}" '
        (if $p != "" then .db_root_password = $p else . end)
        | .db_default_engine = (.db_default_engine // "mariadb")
        | .db_engines = (.db_engines // {})
        | .db_engines.mariadb = ((.db_engines.mariadb // {}) + {installed: $i, port: 3306, server: $f})
    ' > "$tmp" && vault_write server.json < "$tmp"
    rm -f "$tmp"
    _CIPI_MYSQL_FLAVOR="$1"
}

# MySQL is kept off unattended-upgrades as MariaDB is: a database restart is
# not a 4am surprise; `cipi db upgrade` and the nightly autoupdate apply it.
_db_switch_blacklist_mysql() {
    local f="${CIPI_UNATTENDED_FILE:-/etc/apt/apt.conf.d/50cipi-unattended-upgrades}"
    [[ -f "$f" ]] || return 0
    grep -q '"mysql-' "$f" && return 0
    sed -i '/"mariadb-common";/a\    "mysql-.*";' "$f"
}

# cipi db switch <mysql|mariadb> [--yes]
_db_switch() {
    local raw="${1:-}"; shift || true
    parse_args "$@"
    local to
    case "$raw" in
        mysql)   to=mysql ;;
        mariadb) to=mariadb ;;
        *) error "Usage: cipi db switch <mysql|mariadb> [--yes]"; exit 1 ;;
    esac
    db_ensure_engine_state
    local from; from=$(db_mysql_flavor)
    local lf lt; lf=$(_db_server_label "$from"); lt=$(_db_server_label "$to")
    if [[ "$from" == "$to" ]] && db_engine_is_installed mariadb; then
        info "Port 3306 already runs ${lt}"
        return 0
    fi

    # Nothing installed on port 3306 (PostgreSQL is the default): the choice
    # is recorded, and `cipi db install` installs that one.
    if ! db_engine_is_installed mariadb; then
        _db_switch_record "$to" false
        success "Port 3306 will run ${lt} — install it with: cipi db install ${to}"
        log_action "DB SWITCH: port 3306 → ${to} (not installed)"
        return 0
    fi

    # A server with no databases on it, or nothing.
    local dbs apps reg
    if ! dbs=$(db_list_databases mariadb); then
        error "${lf} did not answer — check: cipi service list"
        exit 1
    fi
    apps=$(vault_read apps.json 2>/dev/null | jq -r '
        to_entries[] | select((.value.custom // false) | not)
        | select((.value.engine // "mariadb") == "mariadb") | .key' 2>/dev/null | paste -sd' ' - || true)
    reg=$(vault_read databases.json 2>/dev/null | jq -r '(.mariadb // {}) | keys[]' 2>/dev/null | paste -sd' ' - || true)
    if [[ -n "$dbs" || -n "$apps" || -n "$reg" ]]; then
        error "${lf} → ${lt} runs only on a server with no databases on port 3306: the data is not converted"
        [[ -n "$dbs" ]]  && echo -e "  Databases: $(echo "$dbs" | paste -sd' ' -)"
        [[ -n "$apps" ]] && echo -e "  Apps on ${lf}: ${apps}"
        [[ -n "$reg" && "$reg" != "$(echo "$dbs" | paste -sd' ' -)" ]] && echo -e "  In the registry: ${reg}"
        echo ""
        echo -e "  To move apps to ${lt}: a new server, ${CYAN}cipi db switch ${to}${NC} there before its first app,"
        echo -e "  then ${CYAN}cipi sync${NC} the apps across — this server stays as it is, the way back."
        exit 1
    fi

    if [[ "${ARG_yes:-}" != "true" ]]; then
        if [[ -t 0 ]]; then
            echo ""
            warn "${lf} is removed (packages and configuration) and ${lt} installed on port 3306."
            confirm "Replace ${lf} with ${lt}?" || { info "Cancelled"; return 0; }
        else
            error "Replacing the database server is never implicit: cipi db switch ${to} --yes"
            exit 1
        fi
    fi
    if pgrep -x 'mariadb-dump|mysqldump|mariabackup|mariadb-backup' >/dev/null 2>&1; then
        error "A database dump is running (a backup?) — try again when it is over"
        exit 1
    fi

    _db_switch_run "$from" "$to"
}

_db_switch_run() {   # <from> <to>
    local from="$1" to="$2" ts lf lt data kept cnf pass old_pkgs sim extra
    ts=$(date +%Y%m%d%H%M%S); lf=$(_db_server_label "$from"); lt=$(_db_server_label "$to")
    data=$(_db_mysql_data); kept="${data}.${from}-${ts}"; cnf=$(_db_server_cnf "$from")
    pass=$(db_get_root_password mariadb)
    [[ -n "$pass" && "$pass" != "null" ]] || pass=$(generate_password 40)

    # ── checks: nothing changes when one fails
    step "Checking the ${lt} packages..."
    _db_apt update -qq >/dev/null 2>&1 || true
    if [[ "$to" == "mysql" ]]; then
        local cand; cand=$(_db_apt_candidate mysql-server)
        if [[ -z "$cand" || "$cand" == "(none)" ]]; then
            error "No mysql-server package available from apt — nothing changed"
            LC_ALL=C apt-cache policy mysql-server 2>&1 | sed -n '1,6s/^/  /p' >&2 || true
            echo -e "  ${DIM}Check the sources: apt-get update; apt-cache policy mysql-server${NC}" >&2
            exit 1
        fi
        info "MySQL ${cand%%-*} from the Ubuntu archive"
    fi
    old_pkgs=$(_db_server_pkgs "$from" | paste -sd' ' -)
    if [[ -n "$old_pkgs" ]]; then
        # Removing the server must take nothing else with it: what depends on
        # its client libraries (a Perl or Python driver, a monitoring agent)
        # would go too. Simulated first.
        # shellcheck disable=SC2086
        sim=$(LC_ALL=C _db_apt -s purge $old_pkgs 2>/dev/null) || { error "apt cannot plan the removal of ${lf} — nothing changed"; exit 1; }
        extra=$(awk '/^(Purg|Remv) /{ print $2 }' <<< "$sim" | grep -vxF -f <(tr ' ' '\n' <<< "$old_pkgs") \
                | grep -vE '^(lib(mariadb|mysqlclient)[a-z0-9.-]*|libdbd-(mariadb|mysql)-perl|default-mysql-[a-z-]+|mariadb-[a-z0-9.-]+|mysql-[a-z0-9.-]+|galera-[0-9a-z.-]+)$' \
                | paste -sd' ' - || true)
        if [[ -n "$extra" ]]; then
            error "Removing ${lf} would also remove: ${extra} — nothing changed"
            exit 1
        fi
    fi

    # ── from here the server is down
    log_action "DB SWITCH: ${from} → ${to} started"
    step "Stopping ${lf}..."
    systemctl stop "$(_db_server_unit "$from")" 2>/dev/null || true
    [[ -d "$data" ]] && { mv "$data" "$kept" || { error "Could not move ${data} aside — ${lf} stopped, nothing else changed: systemctl start $(_db_server_unit "$from")"; exit 1; }; }
    [[ -f "$cnf" ]] && mv "$cnf" "${cnf}.cipi-${ts}"
    if [[ -n "$old_pkgs" ]]; then
        step "Removing ${lf}..."
        # shellcheck disable=SC2086
        _db_apt purge -y -qq $old_pkgs >/dev/null 2>&1 || { _db_switch_rollback "$from" "$to" "$ts" "$pass" "removing ${lf} failed"; exit 1; }
    fi
    # MariaDB.org's repository would offer its own mysql-common next to MySQL.
    [[ "$to" == "mysql" ]] && rm -f "${APT_SOURCES_DIR:-/etc/apt/sources.list.d}/mariadb.list"

    step "Installing ${lt}..."
    if ! _db_server_install "$to" "$pass"; then
        _db_switch_rollback "$from" "$to" "$ts" "$pass" "installing ${lt} failed"
        exit 1
    fi
    _db_switch_record "$to" true "$pass"
    [[ "$to" == "mysql" ]] && _db_switch_blacklist_mysql

    local ver; ver=$("$(_db_server_client "$to")" -u root -p"$pass" -N -e "SELECT VERSION();" 2>/dev/null | sed -n 1p) || ver=""
    log_action "DB SWITCH: ${from} → ${to} done (${ver:-?}); ${from} data kept in ${kept}"
    cipi_notify \
        "Cipi: port 3306 now runs ${lt} on $(hostname)" \
        "${lf} was replaced with ${lt} ${ver}.\n\nServer: $(hostname)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')\nThe ${lf} data directory is kept in ${kept}." \
        db_switch 2>/dev/null || true
    success "Port 3306 runs ${lt} ${ver} — same root password, same apps' settings (DB_CONNECTION=mysql)"
    [[ -d "$kept" ]] && info "The ${lf} data directory is kept in ${kept} — remove it when you no longer need it"
    info "Back to ${lf}, while there are no databases: cipi db switch ${from}"
}

# What failed after the old server was stopped: back to it, as far as apt
# allows. Exits through the caller.
_db_switch_rollback() {   # <from> <to> <ts> <root password> <reason>
    local from="$1" to="$2" ts="$3" pass="$4" why="$5" data kept new_pkgs
    data=$(_db_mysql_data); kept="${data}.${from}-${ts}"
    error "${why} — putting $(_db_server_label "$from") back"
    log_action "DB SWITCH: ${from} → ${to} failed (${why}), rolling back"
    systemctl stop "$(_db_server_unit "$to")" 2>/dev/null || true
    new_pkgs=$(_db_server_pkgs "$to" | paste -sd' ' -) || new_pkgs=""
    # Every step is tried: a rollback that stopped half-way would leave
    # neither server (set -e would end it at the first one that fails).
    if [[ -n "$new_pkgs" ]]; then
        # shellcheck disable=SC2086
        _db_apt purge -y -qq $new_pkgs >/dev/null 2>&1 || warn "Could not remove $(_db_server_label "$to")'s packages: ${new_pkgs}"
    fi
    if [[ -d "$data" && -d "$kept" ]]; then
        mv "$data" "${data}.failed-${to}-${ts}" || warn "Could not move ${data} aside"
    fi
    if [[ -d "$kept" && ! -e "$data" ]]; then
        mv "$kept" "$data" || warn "Could not put ${kept} back as ${data}"
    fi
    if [[ "$from" == "mariadb" ]]; then
        # shellcheck source=/dev/null
        source "${CIPI_LIB}/php-apt.sh"
        mariadb_setup_apt_repo || true
    fi
    _db_apt update -qq >/dev/null 2>&1 || true
    local cnf; cnf=$(_db_server_cnf "$from")
    # shellcheck disable=SC2046
    if _db_apt install -y -qq $(_db_server_install_pkgs "$from") >/dev/null 2>&1; then
        [[ -f "${cnf}.cipi-${ts}" ]] && mv -f "${cnf}.cipi-${ts}" "$cnf"
        systemctl restart "$(_db_server_unit "$from")" 2>/dev/null || true
    fi
    _db_switch_record "$from" true "$pass"
    if "$(_db_server_client "$from")" -u root -p"$pass" -N -e "SELECT 1;" >/dev/null 2>&1; then
        warn "$(_db_server_label "$from") is back on port 3306, as it was"
    else
        error "$(_db_server_label "$from") is not answering yet. Its data directory is ${data}; its packages: $(_db_server_install_pkgs "$from")"
        error "  apt-get install $(_db_server_install_pkgs "$from") && systemctl start $(_db_server_unit "$from")"
    fi
}

_db_install_pgsql() {
    if db_engine_is_installed pgsql; then
        info "PostgreSQL is already installed"
        return 0
    fi

    step "Installing PostgreSQL..."
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update -qq
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq postgresql postgresql-contrib \
        || { error "PostgreSQL install failed"; exit 1; }

    systemctl enable --now postgresql

    local pass; pass=$(generate_password 40)

    # Set postgres password + scram auth for TCP localhost
    sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER USER postgres WITH PASSWORD '${pass}';" \
        || { error "Failed to set postgres password"; exit 1; }

    local conf_dir hba conf
    conf_dir=$(sudo -u postgres psql -tAc "SHOW config_file;" 2>/dev/null | xargs dirname)
    if [[ -z "$conf_dir" || ! -d "$conf_dir" ]]; then
        conf_dir=$(ls -d /etc/postgresql/*/main 2>/dev/null | sort -V | tail -1)
    fi
    hba="${conf_dir}/pg_hba.conf"
    conf="${conf_dir}/postgresql.conf"

    if [[ -f "$hba" ]]; then
        # Prefer scram for local TCP; keep peer for local socket admin
        if ! grep -qE '^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1/32[[:space:]]+scram-sha-256' "$hba"; then
            # Comment conflicting host lines for 127.0.0.1 and ::1, then append
            sed -i -E 's/^(host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1\/32[[:space:]].*)/# cipi: \1/' "$hba"
            sed -i -E 's/^(host[[:space:]]+all[[:space:]]+all[[:space:]]+::1\/128[[:space:]].*)/# cipi: \1/' "$hba"
            cat >> "$hba" <<'HBA'

# Cipi — password auth for local TCP
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
HBA
        fi
    fi

    if [[ -f "$conf" ]]; then
        if grep -qE "^#?listen_addresses" "$conf"; then
            sed -i -E "s/^#?listen_addresses.*/listen_addresses = 'localhost'/" "$conf"
        else
            echo "listen_addresses = 'localhost'" >> "$conf"
        fi
        if grep -qE "^#?port[[:space:]]*=" "$conf"; then
            sed -i -E "s/^#?port[[:space:]]*=.*/port = 5432/" "$conf"
        fi
        # Ensure UTF8 default (usually already)
    fi

    # Pin postgresql from unattended-upgrades (managed by cipi)
    if [[ -f /etc/apt/apt.conf.d/50cipi-unattended-upgrades ]]; then
        if ! grep -q '"postgresql' /etc/apt/apt.conf.d/50cipi-unattended-upgrades; then
            sed -i '/"mariadb-common";/a\    "postgresql";\n    "postgresql-.*";\n    "postgresql-common";\n    "postgresql-client.*";' \
                /etc/apt/apt.conf.d/50cipi-unattended-upgrades 2>/dev/null || true
        fi
    fi

    systemctl restart postgresql

    # Verify TCP auth
    if ! PGPASSWORD="$pass" psql -U postgres -h 127.0.0.1 -p 5432 -c '\q' 2>/dev/null; then
        error "PostgreSQL installed but TCP login failed — check pg_hba.conf"
        exit 1
    fi

    local tmp
    tmp=$(mktemp)
    vault_read server.json | jq --arg p "$pass" '
        .db_engines = (.db_engines // {})
        | .db_engines.pgsql = {installed: true, port: 5432, root_password: $p}
        | del(.pgsql_root_password)
    ' > "$tmp"
    vault_write server.json < "$tmp"
    rm -f "$tmp"

    # Ensure nested databases.json has pgsql key
    db_ensure_engine_state
    vault_read databases.json | jq '.pgsql = (.pgsql // {})' | vault_write databases.json

    log_action "DB ENGINE INSTALLED: pgsql"
    cipi_notify \
        "Cipi PostgreSQL installed on $(hostname)" \
        "PostgreSQL was installed.\n\nServer: $(hostname)\nPort: 5432\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        db_install
    success "PostgreSQL installed on port 5432"
    echo -e "  Set as default: ${CYAN}cipi db default pgsql${NC}"
    echo -e "  Create DB:      ${CYAN}cipi db create --engine=pgsql${NC}"
}

_db_uninstall_engine() {
    local raw="${1:-}"
    parse_args "$@"
    [[ -z "$raw" || "$raw" == --* ]] && { error "Usage: cipi db uninstall <mariadb|pgsql> [--force]"; exit 1; }
    local engine
    engine=$(db_normalize_engine "$raw") || { error "Invalid engine '${raw}'. Use: mariadb pgsql"; exit 1; }
    db_ensure_engine_state

    db_engine_is_installed "$engine" || { error "$(db_engine_label "$engine") is not installed"; exit 1; }

    local default; default=$(db_get_default_engine)
    [[ "$engine" == "$default" ]] && {
        error "Cannot uninstall the default engine (${engine}). Switch first: cipi db default <other>"
        exit 1
    }

    # Block if apps still use this engine
    local apps_using
    apps_using=$(vault_read apps.json 2>/dev/null | jq -r --arg e "$engine" '
        to_entries[]
        | select((.value.custom // false | not))
        | select((.value.engine // "mariadb") == $e)
        | .key
    ' 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    if [[ -n "$apps_using" ]]; then
        error "Apps still using $(db_engine_label "$engine"): ${apps_using}"
        echo -e "  Delete those apps first, or migrate them."
        exit 1
    fi

    local db_count
    db_count=$(vault_read databases.json 2>/dev/null | jq --arg e "$engine" '(.[$e] // {}) | length' 2>/dev/null || echo 0)

    if [[ "${ARG_force:-}" != "true" ]] && [[ -t 0 ]]; then
        echo ""
        warn "This will permanently destroy all $(db_engine_label "$engine") data (registry: ${db_count} DB(s))."
        confirm "Uninstall $(db_engine_label "$engine")?" || { info "Cancelled"; return; }
    fi

    step "Uninstalling $(db_engine_label "$engine")..."
    case "$engine" in
        mariadb)
            systemctl stop "$(db_mysql_unit)" 2>/dev/null || true
            local pkgs; pkgs=$(_db_server_pkgs "$(db_mysql_flavor)" | paste -sd' ' -)
            # shellcheck disable=SC2086
            [[ -n "$pkgs" ]] && DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 purge -y -qq \
                $pkgs 2>/dev/null || true
            DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 autoremove -y -qq 2>/dev/null || true
            rm -rf /var/lib/mysql 2>/dev/null || true
            local tmp
            tmp=$(mktemp)
            vault_read server.json | jq '
                .db_engines.mariadb.installed = false
                | del(.db_root_password)
            ' > "$tmp"
            vault_write server.json < "$tmp"
            rm -f "$tmp"
            ;;
        pgsql)
            systemctl stop postgresql 2>/dev/null || true
            DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 purge -y -qq \
                'postgresql*' 2>/dev/null || true
            DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 autoremove -y -qq 2>/dev/null || true
            rm -rf /var/lib/postgresql 2>/dev/null || true
            local tmp
            tmp=$(mktemp)
            vault_read server.json | jq '
                .db_engines.pgsql.installed = false
                | del(.db_engines.pgsql.root_password)
                | del(.pgsql_root_password)
            ' > "$tmp"
            vault_write server.json < "$tmp"
            rm -f "$tmp"
            ;;
    esac

    vault_read databases.json | jq --arg e "$engine" '.[$e] = {}' | vault_write databases.json

    log_action "DB ENGINE UNINSTALLED: $engine"
    cipi_notify \
        "Cipi $(db_engine_label "$engine") uninstalled on $(hostname)" \
        "$(db_engine_label "$engine") was uninstalled (data destroyed).\n\nServer: $(hostname)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        db_uninstall
    success "$(db_engine_label "$engine") uninstalled"
}

_db_set_default() {
    local raw="${1:-}"
    [[ -z "$raw" ]] && { error "Usage: cipi db default <mariadb|pgsql>"; exit 1; }
    local engine
    engine=$(db_require_engine "$raw") || exit 1

    local tmp
    tmp=$(mktemp)
    vault_read server.json | jq --arg e "$engine" '.db_default_engine = $e' > "$tmp"
    vault_write server.json < "$tmp"
    rm -f "$tmp"

    log_action "DB DEFAULT ENGINE: $engine"
    success "Default database engine: $(db_engine_label "$engine") ($(_db_engine_shown "$engine"))"
}

_db_engines() {
    db_ensure_engine_state
    local default; default=$(db_get_default_engine)
    # --json: what the panel reads. "server" says what runs on the engine —
    # mariadb or mysql for the engine "mariadb" (cipi db switch), pgsql —
    # and "label" its name.
    if [[ "${1:-}" == "--json" ]]; then
        local e rows="[]" inst server
        for e in mariadb pgsql; do
            inst=false; db_engine_is_installed "$e" && inst=true
            server="pgsql"; [[ "$e" == "mariadb" ]] && server=$(db_mysql_flavor)
            rows=$(jq -c --arg e "$e" --argjson i "$inst" --argjson p "$(db_engine_port "$e")" --arg d "$default" \
                --arg s "$server" --arg l "$(db_engine_label "$e")" \
                '. + [{engine: $e, status: (if $i then "installed" else "not_installed" end), port: $p,
                       default: ($e == $d), server: $s, label: $l}]' <<< "$rows")
        done
        jq -n --arg d "$default" --argjson e "$rows" '{default: $d, engines: $e}'
        return 0
    fi
    echo -e "\n${BOLD}Database engines${NC}"
    printf "  ${BOLD}%-12s %-14s %-8s %s${NC}\n" "ENGINE" "STATUS" "PORT" "DEFAULT"
    local e status port mark
    for e in mariadb pgsql; do
        port=$(db_engine_port "$e")
        if db_engine_is_installed "$e"; then
            status="installed"
        else
            # ASCII token (not an em dash) so API parsers never mis-read status.
            status="not_installed"
        fi
        mark=""
        [[ "$e" == "$default" ]] && mark="*"
        printf "  %-12s %-14s %-8s %s\n" "$e" "$status" "$port" "$mark"
    done
    echo ""
    echo -e "  Install:  ${CYAN}cipi db install pgsql${NC}"
    echo -e "  Default:  ${CYAN}cipi db default <engine>${NC}"
    if [[ "$(db_mysql_flavor)" == "mysql" ]]; then
        echo -e "  Port 3306 runs MySQL (engine id: mariadb). Back to MariaDB: ${CYAN}cipi db switch mariadb${NC}"
    else
        echo -e "  MySQL instead of MariaDB (no databases yet): ${CYAN}cipi db switch mysql${NC}"
    fi
    echo ""
}

# ── CRUD ──────────────────────────────────────────────────────

_db_create() {
    parse_args "$@"
    local engine
    # Wizard: no --engine on a terminal and both engines installed → a menu,
    # the server default pre-selected (same as cipi app create). Asked here,
    # not inside $(…), where the menu would not be seen.
    if [[ -z "${ARG_engine:-}" && -t 0 ]]; then
        db_ensure_engine_state
        if db_engine_is_installed mariadb && db_engine_is_installed pgsql; then
            local choice
            read_choice "Database engine" "$(db_get_default_engine)" choice "mariadb|MariaDB" "pgsql|PostgreSQL"
            ARG_engine="$choice"
        fi
    fi
    engine=$(db_resolve_engine_arg) || exit 1

    local name="${ARG_name:-}" user="${ARG_user:-}"
    [[ -z "$name" ]] && read_input "Database name" "" name
    [[ -z "$name" ]] && { error "Name required"; exit 1; }
    validate_db_name "$name" || { error "Invalid name"; exit 1; }
    [[ -z "$user" ]] && user="$name"
    validate_db_name "$user" || { error "Invalid user"; exit 1; }
    # --app=<app>: the database is shown as that app's (cipi db list, cipi app
    # show, the panel). Checked before anything is created.
    local link_app="${ARG_app:-}"
    if [[ -n "$link_app" ]]; then
        [[ "$link_app" != "true" ]] || { error "--app needs a name: --app=<app>"; exit 1; }
        app_exists "$link_app" || { error "App '${link_app}' not found"; exit 1; }
    fi

    # Collision within same engine
    local meta
    meta=$(vault_read databases.json 2>/dev/null) || meta="{}"
    if echo "$meta" | jq -e --arg e "$engine" --arg n "$name" '.[$e][$n]' &>/dev/null; then
        error "Database '${name}' already exists on $(_db_engine_shown "$engine")"; exit 1
    fi

    local pass; pass=$(generate_password 40)
    step "Creating database on $(db_engine_label "$engine")..."
    db_create_database "$engine" "$name" "$user" "$pass" || { error "Create failed"; exit 1; }
    _db_meta_set "$engine" "$name" "$user"
    [[ -n "$link_app" ]] && _db_link_set "$link_app" "$engine" "$name"

    log_action "DB CREATED: $name ($engine)${link_app:+ for $link_app}"
    cipi_notify \
        "Cipi database created: ${name} ($(_db_engine_shown "$engine" always)) on $(hostname)" \
        "A database was created.\n\nServer: $(hostname)\nEngine: $(_db_engine_shown "$engine" always)\nDatabase: ${name}\nUser: ${user}${link_app:+\\nApp: ${link_app}}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        db_create
    echo -e "\n${GREEN}✓${NC} Engine: ${CYAN}$(_db_engine_shown "$engine")${NC}  Database: ${CYAN}${name}${NC}  User: ${CYAN}${user}${NC}  Password: ${CYAN}${pass}${NC}"
    [[ -n "$link_app" ]] && echo -e "  App: ${CYAN}${link_app}${NC}"
    echo -e "${YELLOW}Save this password!${NC}\n"
    return 0
}

# Who a database belongs to, for cipi db list: "<app>\t<kind>" — linked (an
# explicit link), own (the database created with a Laravel app), namespace
# (<app>_…, what cipi.yml lets an app declare) — or nothing.
# Reads _DBL_LINK, _DBL_OWN and _DBL_APPS of the caller.
_db_list_owner() {   # <engine> <database>
    local engine="$1" db="$2" a best=""
    if [[ -n "${_DBL_LINK["${engine}/${db}"]:-}" ]]; then
        printf '%s\tlinked' "${_DBL_LINK["${engine}/${db}"]}"; return 0
    fi
    if [[ "${_DBL_OWN["$db"]:-}" == "$engine" ]]; then
        printf '%s\town' "$db"; return 0
    fi
    for a in $_DBL_APPS; do
        [[ "$db" == "${a}_"* && ${#a} -gt ${#best} ]] && best="$a"
    done
    [[ -n "$best" ]] && printf '%s\tnamespace' "$best"
    return 0
}

# One database of the list: a table row, or a JSON line when --json.
_db_list_row() {   # <engine> <database> <user> <size MB>
    local engine="$1" db="$2" u="$3" sz="$4" o app="" kind=""
    o=$(_db_list_owner "$engine" "$db")
    [[ -n "$o" ]] && { app="${o%%$'\t'*}"; kind="${o#*$'\t'}"; }
    if [[ "$_DBL_JSON" == true ]]; then
        _DBL_ROWS+=("$(jq -cn --arg e "$engine" --arg n "$db" --arg u "$u" --arg s "$sz" --arg a "$app" --arg k "$kind" '
            {engine: $e, name: $n, user: (if $u == "" or $u == "—" then null else $u end),
             size_mb: ($s | tonumber? // 0), size: ($s + " MB"),
             app: (if $a == "" then null else $a end), link: (if $k == "" then null else $k end)}')")
        return 0
    fi
    if [[ "$_DBL_APP_COL" == true ]]; then
        local label="—"
        [[ -n "$app" ]] && label="$app"
        [[ "$kind" == "linked" ]] && label="${label} ${DIM}(linked)${NC}"
        tbl_row "$(_db_engine_shown "$engine")" "$db" "$u" "${sz} MB" "$label"
    else
        tbl_row "$(_db_engine_shown "$engine")" "$db" "$u" "${sz} MB"
    fi
}

# cipi db list [--engine=] [--json]
#
# The APP column is for a person at a terminal. The panel API before 1.39
# reads this table with a regex that takes everything after the user as the
# size, and the other lines as database names: piped or run by the panel the
# table keeps the four columns it always had, and --json carries the rest.
_db_list() {
    parse_args "$@"
    local filter="${ARG_engine:-}"
    local engines=()
    if [[ -n "$filter" ]]; then
        local e
        e=$(db_require_engine "$filter") || exit 1
        engines=("$e")
    else
        db_ensure_engine_state
        local e
        for e in mariadb pgsql; do
            db_engine_is_installed "$e" && engines+=("$e")
        done
    fi

    [[ ${#engines[@]} -eq 0 ]] && { error "No database engines installed"; exit 1; }

    local db_meta app_meta
    db_meta=$(vault_read databases.json 2>/dev/null) || db_meta="{}"
    app_meta=$(vault_read apps.json 2>/dev/null) || app_meta="{}"

    local _DBL_JSON=false _DBL_APP_COL=false _DBL_APPS="" _la _le _ln
    local -a _DBL_ROWS=()
    local -A _DBL_LINK=() _DBL_OWN=()
    [[ "${ARG_json:-}" == "true" ]] && _DBL_JSON=true
    [[ "$_DBL_JSON" == false && -t 1 ]] && _DBL_APP_COL=true
    while IFS=$'\t' read -r _la _le _ln; do
        [[ -n "$_la" && -n "$_ln" ]] && _DBL_LINK["${_le}/${_ln}"]="$_la"
    done < <(jq -r 'to_entries[] | .key as $a | (.value.databases // [])[] | select((.name // "") != "") | [$a, (.engine // "mariadb"), .name] | @tsv' <<< "$app_meta" 2>/dev/null || true)
    while IFS=$'\t' read -r _la _le; do
        [[ -n "$_la" ]] && _DBL_OWN["$_la"]="$_le"
    done < <(jq -r 'to_entries[] | select((.value.custom // false) != true) | [.key, (.value.engine // "mariadb")] | @tsv' <<< "$app_meta" 2>/dev/null || true)
    _DBL_APPS=$(jq -r 'keys[]' <<< "$app_meta" 2>/dev/null | tr '\n' ' ' || true)

    if [[ "$_DBL_JSON" == false ]]; then
        echo -e "\n${BOLD}Databases${NC}"
        tbl_start
        if [[ "$_DBL_APP_COL" == true ]]; then
            tbl_head "ENGINE" "DATABASE" "USER" "SIZE" "APP"
        else
            tbl_head "ENGINE" "DATABASE" "USER" "SIZE"
        fi
    fi

    local engine
    for engine in "${engines[@]}"; do
        case "$engine" in
            mariadb)
                local dbr rows
                dbr=$(db_get_root_password mariadb) || { error "Cannot read $(db_mysql_label) credentials from vault"; exit 1; }
                [[ -z "$dbr" || "$dbr" == "null" ]] && { error "$(db_mysql_label) root password not configured (reset with: cipi reset db-password)"; exit 1; }
                if ! rows=$("$(db_mysql_client)" -u root -p"$dbr" -N -e "
                    SELECT s.schema_name,
                           COALESCE(ROUND(SUM(t.data_length + t.index_length) / 1024 / 1024, 2), 0)
                    FROM information_schema.schemata s
                    LEFT JOIN information_schema.tables t ON t.table_schema = s.schema_name
                    WHERE s.schema_name NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys')
                    GROUP BY s.schema_name
                    ORDER BY s.schema_name;" 2>&1); then
                    error "$(db_mysql_label) query failed: ${rows}"
                    exit 1
                fi
                while IFS=$'\t' read -r db sz; do
                    [[ -z "$db" ]] && continue
                    local u
                    u=$(echo "$db_meta" | jq -r --arg n "$db" '(.mariadb[$n].user // empty)' 2>/dev/null)
                    if [[ -z "$u" ]]; then
                        u=$(echo "$app_meta" | jq -r --arg n "$db" 'if has($n) then $n else empty end' 2>/dev/null)
                    fi
                    [[ -z "$u" ]] && u="—"
                    [[ -z "$sz" || "$sz" == "NULL" ]] && sz="0"
                    _db_list_row "mariadb" "$db" "$u" "$sz"
                done <<< "$rows"
                ;;
            pgsql)
                local rows
                if ! rows=$(_db_pgsql_exec -tAc "
                    SELECT datname || E'\t' || COALESCE(ROUND(pg_database_size(datname)/1024.0/1024.0, 2)::text, '0')
                    FROM pg_database
                    WHERE datistemplate = false AND datname NOT IN ('postgres')
                    ORDER BY datname;" 2>&1); then
                    error "PostgreSQL query failed: ${rows}"
                    exit 1
                fi
                while IFS=$'\t' read -r db sz; do
                    db=$(echo "$db" | xargs)
                    sz=$(echo "$sz" | xargs)
                    [[ -z "$db" ]] && continue
                    local u
                    u=$(echo "$db_meta" | jq -r --arg n "$db" '(.pgsql[$n].user // empty)' 2>/dev/null)
                    if [[ -z "$u" ]]; then
                        u=$(echo "$app_meta" | jq -r --arg n "$db" --arg e "pgsql" '
                            if (.[$n].engine // "mariadb") == $e then $n else empty end
                        ' 2>/dev/null)
                    fi
                    [[ -z "$u" ]] && u="—"
                    [[ -z "$sz" || "$sz" == "NULL" ]] && sz="0"
                    _db_list_row "pgsql" "$db" "$u" "$sz"
                done <<< "$rows"
                ;;
        esac
    done
    if [[ "$_DBL_JSON" == true ]]; then
        if [[ ${#_DBL_ROWS[@]} -gt 0 ]]; then
            printf '%s\n' "${_DBL_ROWS[@]}" | jq -s '{databases: .}'
        else
            echo '{"databases": []}'
        fi
        return 0
    fi
    tbl_print
    echo ""
}

_db_resolve_name_engine() {
    # Sets RESOLVED_ENGINE from --engine, registry, or default. parse_args already done.
    local name="$1"
    local engine="" rc=0
    if [[ -n "${ARG_engine:-}" ]]; then
        engine=$(db_require_engine "${ARG_engine}") || return 1
    else
        engine=$(db_lookup_engine_for_name "$name") && rc=0 || rc=$?
        if [[ $rc -eq 2 ]]; then
            error "Database '${name}' exists on multiple engines. Pass --engine=mariadb|pgsql"
            return 1
        fi
        if [[ $rc -ne 0 || -z "$engine" ]]; then
            engine=$(db_get_default_engine)
        fi
        engine=$(db_require_engine "$engine") || return 1
    fi
    RESOLVED_ENGINE="$engine"
}

_db_delete() {
    local name="${1:-}"; [[ -z "$name" ]] && { error "Usage: cipi db delete <name> [--engine=] [--force]"; exit 1; }
    validate_db_name "$name" || { error "Invalid name"; exit 1; }
    parse_args "$@"
    if [[ "${ARG_force:-}" != "true" ]] && [[ -t 0 ]]; then
        confirm "Delete database '${name}'?" || { info "Cancelled"; return; }
    fi
    local RESOLVED_ENGINE=""
    _db_resolve_name_engine "$name" || exit 1
    local engine="$RESOLVED_ENGINE"
    local u; u=$(_db_meta_user "$engine" "$name")
    validate_db_name "$u" || { error "Invalid stored user for '${name}'"; exit 1; }
    db_drop_database "$engine" "$name" "$u"
    _db_meta_del "$engine" "$name"
    _db_link_del "$engine" "$name"
    log_action "DB DELETED: $name ($engine)"
    cipi_notify \
        "Cipi database deleted: ${name} ($(_db_engine_shown "$engine" always)) on $(hostname)" \
        "A database was deleted.\n\nServer: $(hostname)\nEngine: $(_db_engine_shown "$engine" always)\nDatabase: ${name}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        db_delete
    success "'${name}' deleted ($(_db_engine_shown "$engine"))"
}

_db_backup() {
    local name="${1:-}"; [[ -z "$name" ]] && { error "Usage: cipi db backup <name> [--engine=]"; exit 1; }
    validate_db_name "$name" || { error "Invalid name"; exit 1; }
    parse_args "$@"
    local RESOLVED_ENGINE=""
    _db_resolve_name_engine "$name" || exit 1
    local engine="$RESOLVED_ENGINE"
    local dir="${CIPI_LOG}/backups"; mkdir -p "$dir"
    local f="${dir}/${engine}_${name}_$(date +%Y%m%d_%H%M%S).sql.gz"
    step "Backing up '${name}' ($(_db_engine_shown "$engine"))..."
    db_dump_database "$engine" "$name" "$f" || { error "Backup failed"; rm -f "$f"; exit 1; }
    success "Saved: ${f} ($(du -h "$f"|cut -f1))"
}

_db_restore() {
    local name="${1:-}" file="${2:-}"
    [[ -z "$name" || -z "$file" ]] && { error "Usage: cipi db restore <name> <file> [--engine=] [--force]"; exit 1; }
    validate_db_name "$name" || { error "Invalid name"; exit 1; }
    # In an app's home or in a panel tree the file is looked at, and later
    # opened, by the user that tree belongs to (db_dump_reader).
    local reader; reader=$(db_dump_reader "$file")
    if [[ -n "$reader" ]]; then
        app_as "$reader" test -f "$file" < /dev/null 2>/dev/null || { error "File not found (or not readable by ${reader}): $file"; exit 1; }
    else
        [[ ! -f "$file" ]] && { error "File not found: $file"; exit 1; }
    fi
    parse_args "$@"
    if [[ "${ARG_force:-}" != "true" ]] && [[ -t 0 ]]; then
        confirm "Restore '${name}' from '${file}'?" || { info "Cancelled"; return; }
    fi
    local RESOLVED_ENGINE=""
    _db_resolve_name_engine "$name" || exit 1
    local engine="$RESOLVED_ENGINE"
    step "Restoring '${name}' ($(_db_engine_shown "$engine"))..."
    db_restore_database "$engine" "$name" "$file" || { error "Restore failed"; exit 1; }
    success "'${name}' restored ($(_db_engine_shown "$engine"))"
}

_db_password() {
    local name="${1:-}"; [[ -z "$name" ]] && { error "Usage: cipi db password <name> [--engine=]"; exit 1; }
    validate_db_name "$name" || { error "Invalid name"; exit 1; }
    parse_args "$@"
    local RESOLVED_ENGINE=""
    _db_resolve_name_engine "$name" || exit 1
    local engine="$RESOLVED_ENGINE"
    local u; u=$(_db_meta_user "$engine" "$name")
    validate_db_name "$u" || { error "Invalid stored user for '${name}'"; exit 1; }
    local np; np=$(generate_password 40)
    db_change_user_password "$engine" "$u" "$np" || { error "Password change failed"; exit 1; }
    echo -e "\n${GREEN}✓${NC} New password for '${u}' ($(_db_engine_shown "$engine")): ${CYAN}${np}${NC}"
    echo -e "${YELLOW}Update DB_PASSWORD in your .env!${NC}\n"
}
