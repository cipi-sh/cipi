#!/bin/bash
#############################################
# Cipi — Disk usage: the server and each app
#
#   cipi disk [--json]
#
# An app's share is its home (/home/<app>: releases, shared storage, logs) plus
# its database, measured on disk. Percentages are of the size of the filesystem
# that holds /home.
#
# An app may have a soft limit in GB (cipi app limits <app> --disk=N, none by
# default). Nothing is blocked when it is passed: `cipi monitor` alerts
# (check app_disk) and this report marks the row.
#############################################

[[ -z "${DISK_MARIADB_DIR:-}" ]] && readonly DISK_MARIADB_DIR="/var/lib/mysql"

disk_command() {
    local json=false a
    for a in "$@"; do
        case "$a" in
            --json) json=true ;;
            *) error "Usage: cipi disk [--json]"; exit 1 ;;
        esac
    done
    _disk_report "$json"
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

_disk_pct() {
    awk -v kb="${1:-0}" -v size="${2:-0}" 'BEGIN { if (size > 0) printf "%.1f", kb * 100 / size; else printf "0.0" }'
}

# Whole percent of a limit in GB that <KiB> amounts to.
_disk_limit_pct() {
    awk -v kb="${1:-0}" -v gb="${2:-0}" 'BEGIN { if (gb > 0) printf "%d", kb * 100 / (gb * 1048576); else printf "0" }'
}

# "<database>|<KiB>" for every PostgreSQL database; nothing when it is not
# installed or does not answer.
_disk_pgsql_sizes() {
    command -v psql >/dev/null 2>&1 || return 0
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/db.sh"
    _db_pgsql_exec -tAc "SELECT datname || '|' || (pg_database_size(datname) / 1024)
                         FROM pg_database WHERE datistemplate = false;" 2>/dev/null || true
}

# _disk_app_usage <app> <engine> [pgsql sizes] — prints "<files KiB> <database KiB>".
_disk_app_usage() {
    local app="$1" engine="${2:-mariadb}" pg_sizes="${3:-}" files_kb db_kb
    files_kb=$(_disk_kb "/home/${app}")
    if [[ "$engine" == "pgsql" ]]; then
        db_kb=$(awk -F'|' -v d="$app" '$1 == d {print int($2)}' <<< "$pg_sizes" | head -1)
        [[ "$db_kb" =~ ^[0-9]+$ ]] || db_kb=0
    else
        db_kb=$(_disk_kb "${DISK_MARIADB_DIR}/${app}")
    fi
    echo "${files_kb} ${db_kb}"
}

# Percent of its limit at which an app is flagged before it is over (the
# monitor's app_disk warn threshold, 90 unless changed).
_disk_limit_warn() {
    local w
    w=$(vault_read monitor.json 2>/dev/null | jq -r '.checks.app_disk.warn // 90' 2>/dev/null || true)
    [[ "$w" =~ ^[0-9]+$ ]] && echo "$w" || echo 90
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

    local pg_sizes=""
    if grep -q '^[^|]*|pgsql|' <<< "$apps"; then
        pg_sizes=$(_disk_pgsql_sizes)
    fi

    # rows: <total KiB>|<app>|<files KiB>|<database KiB>|<limit GB or empty>, largest first
    local rows="" app engine limit files_kb db_kb
    while IFS='|' read -r app engine limit; do
        [[ -n "$app" ]] || continue
        read -r files_kb db_kb <<< "$(_disk_app_usage "$app" "$engine" "$pg_sizes")"
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
        printf "  %-22s %9s GB %9s GB %9s GB ${color}%7s${NC}\n" \
            "$fs_mount" "$(_disk_gb "$fs_size")" "$(_disk_gb "$fs_used")" "$(_disk_gb "$fs_free")" "$fs_cap"
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
            printf "  %-22s %9s GB %9s GB ${CYAN}%9s GB${NC} %6s%%  %b\n" \
                "$app" "$(_disk_gb "$files_kb")" "$(_disk_gb "$db_kb")" "$(_disk_gb "$t")" "$(_disk_pct "$t" "$size_kb")" "$ltext"
        done <<< "$rows"
        echo "  ─────────────────────────────────────────────────────────────────────────────────────"
        printf "  ${BOLD}%-22s %12s %12s %9s GB %6s%%${NC}\n" \
            "All apps" "" "" "$(_disk_gb "$apps_kb")" "$(_disk_pct "$apps_kb" "$size_kb")"
    fi
    printf "  %-22s %12s %12s %9s GB %6s%%\n" \
        "Everything else" "" "" "$(_disk_gb "$other_kb")" "$(_disk_pct "$other_kb" "$size_kb")"
    echo -e "  ${DIM}Everything else: system, packages, logs, local backups, other databases.${NC}"
    echo -e "  ${DIM}Limit: cipi app limits <app> --disk=<GB>|none — a notification threshold, nothing is blocked.${NC}"
    if [[ "$over" -gt 0 ]]; then
        echo -e "  ${RED}${over} app(s) over the limit.${NC}"
    fi
    echo ""
}
