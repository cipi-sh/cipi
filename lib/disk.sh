#!/bin/bash
#############################################
# Cipi — Disk usage
#
#   cipi disk [--json]        the server's filesystems, then every app
#   cipi disk db [--json]     databases: MariaDB, PostgreSQL, Valkey, Meilisearch
#
# An app's share is its home (/home/<app>: releases, shared storage, logs) plus
# its database. Percentages are of the size of the filesystem that holds /home.
#
# The database is the one named after the app and, when shared/.env points
# somewhere else, the one in DB_DATABASE. Its size is the one `cipi disk db`
# lists: what the server reports and, for MariaDB, the database's directory,
# whichever is larger. If the server does not answer, the directory alone.
#
# An app may have a soft limit in GB on that total (cipi app limits <app>
# --disk=N, none by default). Nothing is blocked when it is passed: `cipi
# monitor` alerts (check app_disk) and this report marks the row.
#############################################

[[ -z "${DISK_MARIADB_DIR:-}" ]] && readonly DISK_MARIADB_DIR="/var/lib/mysql"
[[ -z "${DISK_PGSQL_DIR:-}" ]]   && readonly DISK_PGSQL_DIR="/var/lib/postgresql"
[[ -z "${DISK_VALKEY_DIR:-}" ]]  && readonly DISK_VALKEY_DIR="/var/lib/valkey"

disk_command() {
    local json=false what="apps" a
    for a in "$@"; do
        case "$a" in
            --json)              json=true ;;
            db|dbs|databases)    what="db" ;;
            *) error "Usage: cipi disk [--json] | cipi disk db [--json]"; exit 1 ;;
        esac
    done
    if [[ "$what" == "db" ]]; then
        _disk_db_report "$json"
    else
        _disk_report "$json"
    fi
}

# Size of a tree in KiB, 0 when it is not there. -x: stay on its filesystem.
_disk_kb() {
    local kb
    kb=$(du -skx "$1" 2>/dev/null | awk 'NR==1 {print $1}' || true)
    [[ "$kb" =~ ^[0-9]+$ ]] && echo "$kb" || echo 0
}

_disk_gb() {
    awk -v kb="${1:-0}" 'BEGIN { printf "%.2f", kb / 1048576 }'
}

# A size for a table cell: GB, or MB below 0.01 GB so that a small database
# does not read as 0.00 GB.
_disk_h() {
    awk -v kb="${1:-0}" 'BEGIN {
        if (kb >= 10486)     printf "%.2f GB", kb / 1048576
        else if (kb >= 103)  printf "%.1f MB", kb / 1024
        else if (kb > 0)     printf "<0.1 MB"
        else                 printf "0.00 GB"
    }'
}

_disk_mb() {
    awk -v kb="${1:-0}" 'BEGIN { if (kb > 0 && kb < 103) printf "<0.1"; else printf "%.1f", kb / 1024 }'
}

_disk_pct() {
    awk -v kb="${1:-0}" -v size="${2:-0}" 'BEGIN { if (size > 0) printf "%.1f", kb * 100 / size; else printf "0.0" }'
}

# Whole percent of a limit in GB that <KiB> amounts to.
_disk_limit_pct() {
    awk -v kb="${1:-0}" -v gb="${2:-0}" 'BEGIN { if (gb > 0) printf "%d", kb * 100 / (gb * 1048576); else printf "0" }'
}

# Percent of its limit at which an app is flagged before it is over (the
# monitor's app_disk warn threshold, 90 unless changed).
_disk_limit_warn() {
    local w
    w=$(vault_read monitor.json 2>/dev/null | jq -r '.checks.app_disk.warn // 90' 2>/dev/null || true)
    [[ "$w" =~ ^[0-9]+$ ]] && echo "$w" || echo 90
}

# ── cipi disk ────────────────────────────────────────────────

# What MariaDB and PostgreSQL report for every database, as the row lines of
# `cipi disk db` (row|<engine>|<database>|<KiB>|), without the engine totals.
_disk_sql_sizes() {
    { ( _disk_db_mariadb rows ) || true; ( _disk_db_pgsql rows ) || true; } | grep '^row|' || true
}

# Database names of an app: its own, and DB_DATABASE of shared/.env when the
# app was pointed at another one. A name ends up in a path, so anything that is
# not a plain identifier (a SQLite file, for one) is ignored.
_disk_app_dbnames() {
    local app="$1" name
    echo "$app"
    name=$(grep -m1 '^DB_DATABASE=' "/home/${app}/shared/.env" 2>/dev/null | cut -d= -f2- | tr -d "\"'[:space:]" || true)
    if [[ "$name" =~ ^[A-Za-z0-9_]+$ && "$name" != "$app" ]]; then
        echo "$name"
    fi
}

# _disk_app_usage <app> <engine> [sql sizes] — prints "<files KiB> <database KiB>".
_disk_app_usage() {
    local app="$1" engine="${2:-mariadb}" sizes="${3:-}"
    local files_kb db_kb=0 name kb
    files_kb=$(_disk_kb "/home/${app}")
    [[ "$engine" == "pgsql" ]] || engine="mariadb"
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        kb=$(awk -F'|' -v e="$engine" -v d="$name" '$2 == e && $3 == d {print int($4)}' <<< "$sizes" | head -1)
        if [[ ! "$kb" =~ ^[0-9]+$ ]]; then
            # Not in what the server reported (it did not answer): the directory alone.
            kb=0
            [[ "$engine" == "mariadb" ]] && kb=$(_disk_kb "${DISK_MARIADB_DIR}/${name}")
        fi
        db_kb=$((db_kb + kb))
    done <<< "$(_disk_app_dbnames "$app")"
    echo "${files_kb} ${db_kb}"
}

_disk_report() {
    local json="$1"

    # The filesystem /home is on: every percentage refers to its size.
    local mount size_kb used_kb free_kb cap
    read -r size_kb used_kb free_kb cap mount < <(df -Pk /home 2>/dev/null | awk 'NR==2 {print $2, $3, $4, $5, $6}') || true
    if [[ ! "${size_kb:-}" =~ ^[0-9]+$ || "$size_kb" -eq 0 ]]; then
        error "Could not read the disk size (df /home)"
        exit 1
    fi
    cap="${cap%\%}"
    [[ "$cap" =~ ^[0-9]+$ ]] || cap=0

    local apps=""
    if [[ -f "${CIPI_CONFIG}/apps.json" ]]; then
        apps=$(vault_read apps.json 2>/dev/null \
            | jq -r 'to_entries[] | "\(.key)|\(.value.engine // "mariadb")|\(.value.disk_limit_gb // "")"' 2>/dev/null || true)
    fi

    local n=0
    [[ -n "$apps" ]] && n=$(grep -c . <<< "$apps" || true)
    if [[ "$json" == false && -t 2 && "$n" -gt 0 ]]; then
        echo -ne "  ${DIM}Measuring ${n} app(s)…${NC}\r" >&2
    fi

    local sql_sizes=""
    [[ "$n" -gt 0 ]] && sql_sizes=$(_disk_sql_sizes)

    # rows: <total KiB>|<app>|<files KiB>|<database KiB>|<limit GB or empty>, largest first
    local rows="" app engine limit files_kb db_kb
    while IFS='|' read -r app engine limit; do
        [[ -n "$app" ]] || continue
        read -r files_kb db_kb <<< "$(_disk_app_usage "$app" "$engine" "$sql_sizes")"
        rows+="$((files_kb + db_kb))|${app}|${files_kb}|${db_kb}|${limit}"$'\n'
    done <<< "$apps"
    rows=$(printf '%s' "$rows" | sort -t'|' -k1,1nr -k2,2)

    local apps_kb=0 t
    while IFS='|' read -r t _; do
        if [[ -n "$t" ]]; then apps_kb=$((apps_kb + t)); fi
    done <<< "$rows"
    local other_kb=$((used_kb - apps_kb))
    [[ "$other_kb" -lt 0 ]] && other_kb=0

    if [[ "$json" == true ]]; then
        printf '%s\n' "$rows" | jq -Rn --arg mount "$mount" --argjson size "$size_kb" --argjson used "$used_kb" \
            --argjson free "$free_kb" --argjson cap "$cap" '
            def gb: (. / 1048576 * 100 | round) / 100;
            def pct: (. * 1000 / $size | round) / 10;
            [inputs | select(length > 0) | split("|")
                | {app: .[1], files: (.[2] | tonumber), db: (.[3] | tonumber),
                   limit: (if (.[4] // "") == "" then null else (.[4] | tonumber) end)}] as $a
            | ($a | map(.files + .db) | add // 0) as $apps
            | {
                disk: {mount: $mount, size_gb: ($size | gb), used_gb: ($used | gb), free_gb: ($free | gb), used_percent: $cap},
                apps: [$a[] | (.files + .db) as $t | {app, files_gb: (.files | gb), database_gb: (.db | gb),
                               total_gb: ($t | gb), percent: ($t | pct),
                               files_kb: .files, database_kb: .db, total_kb: $t,
                               limit_gb: .limit,
                               limit_percent: (if .limit then ($t * 100 / (.limit * 1048576) | floor) else null end),
                               over_limit: (if .limit then $t > .limit * 1048576 else false end)}],
                apps_total_gb: ($apps | gb),
                apps_percent: ($apps | pct),
                other_gb: ([$used - $apps, 0] | max | gb),
                other_percent: ([$used - $apps, 0] | max | pct)
              }'
        return 0
    fi

    [[ -t 2 ]] && echo -ne "\033[2K" >&2
    echo ""
    echo -e "  ${BOLD}Server disk${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  ${BOLD}%-22s %12s %12s %12s %7s${NC}\n" "MOUNT" "SIZE" "USED" "FREE" "USE"
    local fs_mount fs_size fs_used fs_free fs_cap color
    while read -r fs_size fs_used fs_free fs_cap fs_mount; do
        [[ -n "$fs_mount" ]] || continue
        color="$GREEN"
        if [[ "${fs_cap%\%}" =~ ^[0-9]+$ ]]; then
            if   [[ "${fs_cap%\%}" -ge 90 ]]; then color="$RED"
            elif [[ "${fs_cap%\%}" -ge 80 ]]; then color="$YELLOW"; fi
        fi
        printf "  %-22s %12s %12s %12s ${color}%7s${NC}\n" \
            "$fs_mount" "$(_disk_h "$fs_size")" "$(_disk_h "$fs_used")" "$(_disk_h "$fs_free")" "$fs_cap"
    done < <(df -Pkl -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2>/dev/null \
                | awk 'NR > 1 {print $2, $3, $4, $5, $6}')

    echo ""
    echo -e "  ${BOLD}Apps (${n})${NC} ${DIM}— % of the $(_disk_gb "$size_kb") GB on ${mount}${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local over=0
    if [[ "$n" -eq 0 ]]; then
        echo -e "  ${DIM}No apps yet${NC}"
    else
        local warn lpct ltext
        warn=$(_disk_limit_warn)
        printf "  ${BOLD}%-22s %12s %12s %12s %7s  %s${NC}\n" "APP" "FILES" "DATABASE" "TOTAL" "DISK" "LIMIT"
        while IFS='|' read -r t app files_kb db_kb limit; do
            [[ -n "$app" ]] || continue
            if [[ -z "$limit" ]]; then
                ltext="${DIM}—${NC}"
            else
                lpct=$(_disk_limit_pct "$t" "$limit")
                if awk -v kb="$t" -v gb="$limit" 'BEGIN { exit !(kb > gb * 1048576) }'; then
                    ltext="${RED}${limit} GB (${lpct}%) over${NC}"
                    over=$((over + 1))
                elif [[ "$lpct" -ge "$warn" ]]; then
                    ltext="${YELLOW}${limit} GB (${lpct}%)${NC}"
                else
                    ltext="${limit} GB (${lpct}%)"
                fi
            fi
            printf "  %-22s %12s %12s ${CYAN}%12s${NC} %6s%%  %b\n" \
                "$app" "$(_disk_h "$files_kb")" "$(_disk_h "$db_kb")" "$(_disk_h "$t")" "$(_disk_pct "$t" "$size_kb")" "$ltext"
        done <<< "$rows"
        echo "  ─────────────────────────────────────────────────────────────────────────────────────"
        printf "  ${BOLD}%-22s %12s %12s %12s %6s%%${NC}\n" \
            "All apps" "" "" "$(_disk_h "$apps_kb")" "$(_disk_pct "$apps_kb" "$size_kb")"
    fi
    printf "  %-22s %12s %12s %12s %6s%%\n" \
        "Everything else" "" "" "$(_disk_h "$other_kb")" "$(_disk_pct "$other_kb" "$size_kb")"
    echo -e "  ${DIM}Everything else: system, packages, logs, local backups, other databases.${NC}"
    echo -e "  ${DIM}Every database: cipi disk db · Limit: cipi app limits <app> --disk=<GB>|none (alerts, blocks nothing)${NC}"
    if [[ "$over" -gt 0 ]]; then
        echo -e "  ${RED}${over} app(s) over the limit.${NC}"
    fi
    echo ""
}

# ── cipi disk db ─────────────────────────────────────────────
#
# Each collector prints lines for the engine it knows, and nothing at all when
# the engine is not installed:
#   row|<engine>|<name>|<KiB or empty>|<items or empty>
#   sum|<engine>|<on_disk|memory>|<KiB>
#   note|<engine>|<text>
# MariaDB and PostgreSQL take an optional "rows" argument that leaves the
# engine total out (cipi disk only needs the databases).
# A collector never fails the report: an engine that does not answer gets a note.

_disk_db_mariadb() {
    local only="${1:-}"
    command -v mariadb >/dev/null 2>&1 || return 0
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/db.sh"
    local out dir name kb du_kb
    out=$(_db_mariadb_exec -N -B -e "
        SELECT CONCAT('datadir|', @@datadir);
        SELECT CONCAT('db|', s.schema_name, '|', COALESCE(FLOOR(SUM(t.data_length + t.index_length) / 1024), 0))
        FROM information_schema.schemata s
        LEFT JOIN information_schema.tables t ON t.table_schema = s.schema_name
        WHERE s.schema_name NOT IN ('information_schema', 'mysql', 'performance_schema', 'sys')
        GROUP BY s.schema_name ORDER BY s.schema_name;" 2>/dev/null || true)
    dir=$(awk -F'|' '$1 == "datadir" {print $2}' <<< "$out" | head -1)
    dir="${dir%/}"
    [[ -n "$dir" ]] || dir="$DISK_MARIADB_DIR"
    if ! grep -q '^datadir|' <<< "$out"; then
        echo "note|mariadb|MariaDB did not answer — check: cipi service list"
    fi
    while IFS='|' read -r _ name kb; do
        [[ -n "$name" ]] || continue
        [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
        # The files include space the server has not handed back; whichever is larger.
        du_kb=$(_disk_kb "${dir}/${name}")
        if (( du_kb > kb )); then kb=$du_kb; fi
        echo "row|mariadb|${name}|${kb}|"
    done <<< "$(grep '^db|' <<< "$out" || true)"
    [[ "$only" == "rows" ]] || echo "sum|mariadb|on_disk|$(_disk_kb "$dir")"
}

_disk_db_pgsql() {
    local only="${1:-}"
    command -v psql >/dev/null 2>&1 || return 0
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/db.sh"
    local out name kb
    out=$(_db_pgsql_exec -tAc "SELECT 'db|' || datname || '|' || (pg_database_size(datname) / 1024)
                               FROM pg_database
                               WHERE datistemplate = false AND datname <> 'postgres'
                               ORDER BY datname;" 2>/dev/null || echo "FAILED")
    if [[ "$out" == "FAILED" ]]; then
        echo "note|pgsql|PostgreSQL did not answer — check: cipi service list"
        out=""
    fi
    while IFS='|' read -r _ name kb; do
        [[ -n "$name" ]] || continue
        [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
        echo "row|pgsql|${name}|${kb}|"
    done <<< "$(grep '^db|' <<< "$out" || true)"
    [[ "$only" == "rows" ]] || echo "sum|pgsql|on_disk|$(_disk_kb "$DISK_PGSQL_DIR")"
}

# Valkey keeps one data set per logical database (db0, db1, …) and knows how
# many keys each holds, not how much memory: the size is the instance's.
_disk_db_valkey() {
    local cli
    cli=$(command -v valkey-cli 2>/dev/null || command -v redis-cli 2>/dev/null || true)
    [[ -n "$cli" ]] || return 0
    local pass info dir
    pass=$(vault_read server.json 2>/dev/null | jq -r '.valkey_password // .redis_password // empty' 2>/dev/null || true)
    # The password goes through the environment, never the argument list
    # (/proc/<pid>/cmdline is world-readable). This runs in the report's subshell.
    if [[ -n "$pass" ]]; then
        export REDISCLI_AUTH="$pass" VALKEYCLI_AUTH="$pass"
    fi
    info=$(_cipi_run_timed 5 "$cli" -h 127.0.0.1 INFO 2>/dev/null | tr -d '\r' || true)
    if ! grep -q '^used_memory:' <<< "$info"; then
        echo "note|valkey|Valkey did not answer — check: cipi service list"
        echo "sum|valkey|on_disk|$(_disk_kb "$DISK_VALKEY_DIR")"
        return 0
    fi
    awk -F'[:=,]' '/^db[0-9]+:keys=/ { print "row|valkey|" $1 "||" $3 }' <<< "$info"
    grep -q '^db[0-9]*:keys=' <<< "$info" || echo "note|valkey|no keys stored"
    echo "sum|valkey|memory|$(awk -F: '$1 == "used_memory" { printf "%d", $2 / 1024 }' <<< "$info")"
    dir=$(_cipi_run_timed 5 "$cli" -h 127.0.0.1 CONFIG GET dir 2>/dev/null | tr -d '\r' | sed -n '2p' || true)
    [[ "$dir" == /* ]] || dir="$DISK_VALKEY_DIR"
    echo "sum|valkey|on_disk|$(_disk_kb "$dir")"
}

# Meilisearch reports documents per index and the size of the whole database;
# a per-index size only where the version exposes it (rawDocumentDbSize).
_disk_db_meilisearch() {
    [[ -f "${CIPI_LIB}/search.sh" ]] || return 0
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/search.sh"
    _search_installed || return 0
    if _search_running && _search_api GET /stats ""; then
        printf '%s' "$_SEARCH_HTTP_BODY" | jq -r '
            (.indexes // {}) | to_entries | sort_by(.key)[]
            | "row|meilisearch|\(.key)|\(if .value.rawDocumentDbSize then (.value.rawDocumentDbSize / 1024 | floor) else "" end)|\(.value.numberOfDocuments // 0)"' 2>/dev/null || true
        printf '%s' "$_SEARCH_HTTP_BODY" | jq -e '(.indexes // {}) | length > 0' >/dev/null 2>&1 \
            || echo "note|meilisearch|no indexes"
    else
        echo "note|meilisearch|Meilisearch did not answer — check: cipi service list"
    fi
    echo "sum|meilisearch|on_disk|$(_disk_kb "${SEARCH_HOME}/data.ms")"
}

# Each collector in a subshell of its own: what one of them sources or exports
# (a password) stays there.
_disk_db_collect() {
    ( _disk_db_mariadb )     || true
    ( _disk_db_pgsql )       || true
    ( _disk_db_valkey )      || true
    ( _disk_db_meilisearch ) || true
}

_disk_db_report() {
    local json="$1" lines
    lines=$(_disk_db_collect)

    if [[ "$json" == true ]]; then
        printf '%s\n' "$lines" | jq -Rn '
            def mb: if . == "" then null else ((tonumber) / 1024 * 10 | round) / 10 end;
            reduce (inputs | select(length > 0) | split("|")) as $r ({};
                if $r[0] == "row" then
                    .[$r[1]].databases += [
                        {name: $r[2], size_mb: ($r[3] | mb)}
                        + (if $r[4] == "" then {}
                           elif $r[1] == "valkey" then {keys: ($r[4] | tonumber)}
                           else {documents: ($r[4] | tonumber)} end)]
                elif $r[0] == "sum" then
                    .[$r[1]][$r[2] + "_mb"] = ($r[3] | mb)
                elif $r[0] == "note" then
                    .[$r[1]].note = $r[2]
                else . end)
            | map_values(.databases //= [])'
        return 0
    fi

    echo ""
    echo -e "  ${BOLD}Databases${NC} ${DIM}— sizes in MB${NC}"
    if [[ -z "$lines" ]]; then
        echo -e "  ${DIM}No database engine found${NC}\n"
        return 0
    fi
    local engine label name_head items_head kind e name kb items
    for engine in mariadb pgsql valkey meilisearch; do
        grep -q "^[a-z]*|${engine}|" <<< "$lines" || continue
        name_head="DATABASE"
        case "$engine" in
            mariadb)     label="MariaDB";     items_head="" ;;
            pgsql)       label="PostgreSQL";  items_head="" ;;
            valkey)      label="Valkey";      items_head="KEYS" ;;
            meilisearch) label="Meilisearch"; items_head="DOCUMENTS"; name_head="INDEX" ;;
        esac
        echo ""
        echo -e "  ${BOLD}${label}${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if grep -q "^row|${engine}|" <<< "$lines"; then
            printf "  ${BOLD}%-36s %12s %14s${NC}\n" "$name_head" "$items_head" "SIZE"
        fi
        while IFS='|' read -r kind e name kb items; do
            [[ "$e" == "$engine" ]] || continue
            case "$kind" in
                row)
                    if [[ -n "$kb" ]]; then
                        printf "  %-36s %12s ${CYAN}%11s MB${NC}\n" "$name" "$items" "$(_disk_mb "$kb")"
                    else
                        printf "  %-36s %12s ${DIM}%14s${NC}\n" "$name" "$items" "—"
                    fi
                    ;;
                sum)
                    case "$name" in
                        memory)  name="Memory in use" ;;
                        on_disk) name="On disk, whole engine" ;;
                    esac
                    printf "  ${DIM}%-36s %12s %11s MB${NC}\n" "$name" "" "$(_disk_mb "$kb")"
                    ;;
                note)
                    echo -e "  ${YELLOW}${name}${NC}"
                    ;;
            esac
        done <<< "$lines"
    done
    echo ""
    echo -e "  ${DIM}MariaDB and PostgreSQL: one size per database. Valkey only knows the keys of each${NC}"
    echo -e "  ${DIM}database, and Meilisearch the documents of each index: their size is the engine's.${NC}"
    echo ""
}
