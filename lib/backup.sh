#!/bin/bash
#############################################
# Cipi — Backup (profiles, S3 / S3-compatible / local)
#
# A backup run is driven by a *profile*: what to take (files, databases, or
# both), which apps and databases it covers, how often it runs, where it goes
# and how long it is kept. Several profiles coexist — e.g. a full nightly copy
# to S3 next to a 30-minute database-only copy kept locally — which is what a
# multi-tenant SaaS needs and what a single hardcoded nightly job could not do.
#
# Layout inside a run (local dir or S3 prefix):
#
#   <root>/<profile>/<timestamp>/manifest.json
#   <root>/<profile>/<timestamp>/apps/<app>/files.tar.gz
#   <root>/<profile>/<timestamp>/apps/<app>/meta.json
#   <root>/<profile>/<timestamp>/databases/<engine>/<db>.sql.gz
#
# Application files and databases are separated, so a database-only profile
# costs nothing in disk or transfer, and a database can be restored without
# unpacking the app.
#############################################

[[ -z "${BACKUP_KEY_FILE:-}" ]] && readonly BACKUP_KEY_FILE="${CIPI_CONFIG}/.backup_key"

# The AWS CLI installs into /usr/local/bin, which root's crontab PATH
# (/usr/bin:/bin) does not include — and every scheduled run comes from cron.
case ":${PATH}:" in *:/usr/local/bin:*) ;; *) export PATH="/usr/local/bin:${PATH}" ;; esac
[[ -z "${BACKUP_DEFAULT_LOCAL:-}" ]] && readonly BACKUP_DEFAULT_LOCAL="/var/backups/cipi"

backup_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        configure) _bk_configure ;;
        status)    _bk_status "$@" ;;
        profile|profiles) _bk_profile_command "$@" ;;
        run)       _bk_run "$@" ;;
        list)      _bk_list "$@" ;;
        prune)     _bk_prune "$@" ;;
        verify)    _bk_verify "$@" ;;
        check)     _bk_check_stale "$@" ;;
        fetch)     _bk_fetch "$@" ;;
        key)       _bk_key_command "$@" ;;
        *) error "Use: configure status profile run list prune verify fetch key"; exit 1 ;;
    esac
}

# ── Config helpers ───────────────────────────────────────────

_bk_cfg()       { vault_read backup.json 2>/dev/null || echo '{}'; }
_bk_cfg_write() { vault_write backup.json; }
_bk_configured() { [[ -f "${CIPI_CONFIG}/backup.json" ]]; }

_bk_require_config() {
    _bk_configured || { error "Backup not configured. Run: cipi backup configure"; exit 1; }
}

_bk_local_root() {
    local d; d=$(_bk_cfg | jq -r '.local_dir // ""')
    echo "${d:-$BACKUP_DEFAULT_LOCAL}"
}

_bk_s3_bucket() { _bk_cfg | jq -r '.bucket // ""'; }
_bk_has_s3()    { [[ -n "$(_bk_s3_bucket)" ]]; }

_ensure_awscli() {
    if ! command -v aws &>/dev/null; then
        step "Installing AWS CLI v2..."
        local tmp; tmp=$(mktemp -d)
        curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "${tmp}/awscliv2.zip"
        unzip -q "${tmp}/awscliv2.zip" -d "${tmp}"
        "${tmp}/aws/install" --update -i /usr/local/aws-cli -b /usr/local/bin &>/dev/null
        rm -rf "${tmp}"
        command -v aws &>/dev/null || { error "AWS CLI install failed"; exit 1; }
        success "AWS CLI $(aws --version 2>&1 | awk '{print $1}')"
    fi
}

# Disk-backed temp dir for archives (default /var/tmp). /tmp is often tmpfs and too small for large apps.
# Override: CIPI_BACKUP_TMPDIR env, or backup.json "tmpdir".
_bk_tmp_base() {
    local dir=""
    if [[ -n "${CIPI_BACKUP_TMPDIR:-}" ]]; then
        dir="$CIPI_BACKUP_TMPDIR"
    elif [[ -f "${CIPI_CONFIG}/backup.json" ]]; then
        dir=$(_bk_cfg | jq -r '.tmpdir // ""')
    fi
    dir="${dir:-/var/tmp}"
    if [[ ! -d "$dir" ]] || [[ ! -w "$dir" ]]; then
        error "Backup temp directory not writable: ${dir}"
        exit 1
    fi
    echo "$dir"
}

# Wrapper: adds --endpoint-url and --region when a custom endpoint is configured.
# S3-compatible APIs can fail with "NoneType is not iterable" if region is empty.
_aws_s3() {
    local ep="" region=""
    if [[ -f "${CIPI_CONFIG}/backup.json" ]]; then
        local _bkj; _bkj=$(_bk_cfg)
        ep=$(echo "$_bkj" | jq -r '.endpoint_url // ""')
        region=$(echo "$_bkj" | jq -r '.region // "eu-central-1"')
    fi
    if [[ -n "$ep" ]]; then
        aws s3 --endpoint-url "$ep" --region "${region:-eu-central-1}" "$@"
    else
        aws s3 "$@"
    fi
}

# ── Encryption ───────────────────────────────────────────────
#
# Archives are encrypted client-side with AES-256-CBC before they leave the
# server, so the bucket operator never holds readable data. The key lives only
# on this server: losing it makes every encrypted archive unrecoverable, which
# is why `cipi backup key show` exists and the setup shouts about it.

_bk_key_ensure() {
    [[ -f "$BACKUP_KEY_FILE" ]] && return 0
    _cipi_ensure_config_writable || { error "Cannot write ${CIPI_CONFIG}"; return 1; }
    openssl rand -base64 48 | tr -d '\n' > "$BACKUP_KEY_FILE" || return 1
    chmod 400 "$BACKUP_KEY_FILE" 2>/dev/null || true
    return 0
}

_bk_encrypt_file() {
    local in="$1" out="$2"
    _bk_key_ensure || return 1
    openssl enc -aes-256-cbc -salt -pbkdf2 -pass "file:${BACKUP_KEY_FILE}" -in "$in" -out "$out"
}

_bk_decrypt_file() {
    local in="$1" out="$2" keyfile="${3:-$BACKUP_KEY_FILE}"
    [[ -f "$keyfile" ]] || { error "Backup key not found: ${keyfile}"; return 1; }
    openssl enc -d -aes-256-cbc -pbkdf2 -pass "file:${keyfile}" -in "$in" -out "$out"
}

_bk_key_command() {
    local sub="${1:-show}"; shift||true
    case "$sub" in
        show)
            _bk_key_ensure || exit 1
            echo -e "\n${BOLD}Backup encryption key${NC}"
            echo -e "  ${DIM}File:${NC} ${BACKUP_KEY_FILE}"
            echo -e "  ${CYAN}$(cat "$BACKUP_KEY_FILE")${NC}"
            echo ""
            echo -e "  ${YELLOW}Store this off the server.${NC} Encrypted archives cannot be read without it —"
            echo -e "  ${DIM}not by Cipi, not by the bucket operator, not by you.${NC}"
            echo ""
            ;;
        rotate)
            echo -e "${YELLOW}Rotating the key does NOT re-encrypt existing archives.${NC}"
            echo -e "${YELLOW}Keep the old key or those backups become unreadable.${NC}"
            if [[ -t 0 ]]; then confirm "Rotate the backup encryption key?" || { info "Cancelled"; return 0; }; fi
            if [[ -f "$BACKUP_KEY_FILE" ]]; then
                local bak="${BACKUP_KEY_FILE}.$(date +%Y%m%d%H%M%S)"
                cp "$BACKUP_KEY_FILE" "$bak" && chmod 400 "$bak"
                warn "Previous key kept at ${bak} — needed to read older archives"
            fi
            _cipi_ensure_config_writable || { error "Cannot write ${CIPI_CONFIG}"; exit 1; }
            rm -f "$BACKUP_KEY_FILE"
            _bk_key_ensure || exit 1
            success "Backup encryption key rotated"
            log_action "BACKUP KEY ROTATED"
            ;;
        *) error "Use: cipi backup key show|rotate"; exit 1 ;;
    esac
}

# ── Profiles ─────────────────────────────────────────────────

_bk_profiles_json() { _bk_cfg | jq '.profiles // {}'; }
_bk_profile_names() { _bk_profiles_json | jq -r 'keys[]' 2>/dev/null || true; }
# jq's `//` treats `false` as absent, so `.[$p][$k] // empty` returned an empty
# string for every boolean that is false — which made `enabled: false` read as
# "not set", and a disabled profile kept running and stayed in the crontab.
_bk_profile_get()   { _bk_profiles_json | jq -r --arg p "$1" --arg k "$2" '.[$p][$k] | if . == null then empty else tostring end'; }
_bk_profile_json()  { _bk_profiles_json | jq --arg p "$1" '.[$p] // empty'; }
_bk_profile_exists() { _bk_profiles_json | jq -e --arg p "$1" 'has($p)' &>/dev/null; }

_bk_profile_list_field() {
    # Print a JSON array field one element per line.
    _bk_profiles_json | jq -r --arg p "$1" --arg k "$2" '(.[$p][$k] // []) | .[]' 2>/dev/null || true
}

_bk_valid_profile_name() {
    [[ "$1" =~ ^[a-z][a-z0-9-]{1,31}$ ]]
}

# Glob list membership: _bk_glob_match <name> <newline-separated globs>
# An empty list means "no match"; a list containing "*" matches everything.
_bk_glob_match() {
    local name="$1" globs="$2" g
    [[ -z "$globs" ]] && return 1
    while IFS= read -r g; do
        [[ -n "$g" ]] || continue
        # shellcheck disable=SC2053
        [[ "$name" == $g ]] && return 0
    done <<< "$globs"
    return 1
}

# Cron expression: exactly 5 whitespace-separated fields of a safe charset.
# Written straight into root's crontab, so nothing else may pass.
_bk_valid_cron() {
    local expr="$1"
    [[ "$expr" =~ ^[0-9*/,[:space:]-]+$ ]] || return 1
    local n; n=$(echo "$expr" | awk '{print NF}')
    [[ "$n" -eq 5 ]]
}

# --every=30m|6h|1d → "<interval-seconds><TAB><cron expression>".
#
# Both values are printed rather than one of them assigned to a global: callers
# use command substitution, and a global set inside that subshell never reaches
# them.
_bk_every_to_cron() {
    local every="$1" num unit
    [[ "$every" =~ ^([0-9]+)([mhd])$ ]] || return 1
    num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
    [[ "$num" -gt 0 ]] || return 1
    case "$unit" in
        m)
            [[ "$num" -le 59 ]] || return 1
            [[ $(( 60 % num )) -eq 0 ]] || return 1
            printf '%s\t%s\n' "$(( num * 60 ))" "*/${num} * * * *"
            ;;
        h)
            [[ "$num" -le 23 ]] || return 1
            [[ $(( 24 % num )) -eq 0 ]] || return 1
            printf '%s\t%s\n' "$(( num * 3600 ))" "0 */${num} * * *"
            ;;
        d)
            [[ "$num" -le 28 ]] || return 1
            if [[ "$num" -eq 1 ]]; then
                printf '%s\t%s\n' "86400" "0 2 * * *"
            else
                printf '%s\t%s\n' "$(( num * 86400 ))" "0 2 */${num} * *"
            fi
            ;;
    esac
}

# Best-effort expected interval for a raw cron expression, used only to decide
# when a profile counts as overdue.
_bk_cron_interval_seconds() {
    local expr="$1"
    local min hour dom mon dow
    read -r min hour dom mon dow <<< "$expr"
    if [[ "$min" =~ ^\*/([0-9]+)$ ]]; then echo $(( BASH_REMATCH[1] * 60 )); return; fi
    if [[ "$min" == "*" ]]; then echo 60; return; fi
    if [[ "$hour" =~ ^\*/([0-9]+)$ ]]; then echo $(( BASH_REMATCH[1] * 3600 )); return; fi
    if [[ "$hour" == "*" ]]; then echo 3600; return; fi
    if [[ "$dow" != "*" ]]; then echo 604800; return; fi
    if [[ "$dom" =~ ^\*/([0-9]+)$ ]]; then echo $(( BASH_REMATCH[1] * 86400 )); return; fi
    if [[ "$dom" != "*" ]]; then echo 2592000; return; fi
    echo 86400
}

_bk_default_profile_json() {
    # Mirrors the pre-5.1 behaviour: one nightly full backup, kept four weeks.
    jq -n '{
        scope: "all",
        apps: ["*"],
        databases: ["*"],
        exclude_databases: [],
        exclude_tables: [],
        cron: "0 2 * * *",
        interval_seconds: 86400,
        destinations: ["s3"],
        retention: { keep: 0, days: 28, weeks: 0 },
        encrypt: false,
        enabled: true,
        created_at: (now | floor)
    }'
}

_bk_profile_save() {
    local name="$1" json="$2"
    _bk_cfg | jq --arg p "$name" --argjson d "$json" '
        .profiles = ((.profiles // {}) | .[$p] = ($d | .created_at = (.created_at // (now | floor))))
    ' | _bk_cfg_write
    _bk_write_cron
}

_bk_ensure_default_profile() {
    _bk_configured || return 0
    local n; n=$(_bk_profiles_json | jq 'length')
    [[ "$n" -gt 0 ]] && return 0
    local d; d=$(_bk_default_profile_json)
    # Without a bucket the only place a backup can land is this server.
    _bk_has_s3 || d=$(echo "$d" | jq '.destinations = ["local"]')
    _bk_profile_save default "$d"
    info "Created backup profile 'default' (nightly 02:00, kept 28 days)"
}

# ── Profile CLI ──────────────────────────────────────────────

_bk_profile_command() {
    local sub="${1:-list}"; shift||true
    case "$sub" in
        list|ls)  _bk_profile_list ;;
        show)     _bk_profile_show "$@" ;;
        add|edit) _bk_profile_add "$sub" "$@" ;;
        remove|rm|delete) _bk_profile_remove "$@" ;;
        enable)   _bk_profile_toggle "${1:-}" true ;;
        disable)  _bk_profile_toggle "${1:-}" false ;;
        *) error "Use: cipi backup profile list|show|add|edit|remove|enable|disable"; exit 1 ;;
    esac
}

_bk_profile_list() {
    _bk_require_config
    _bk_ensure_default_profile
    local names; names=$(_bk_profile_names)
    [[ -z "$names" ]] && { info "No backup profiles. Create one: cipi backup profile add <name> ..."; return 0; }

    local state; state=$(_bk_state)
    echo -e "\n${BOLD}Backup profiles${NC}"
    printf "  ${BOLD}%-16s %-6s %-15s %-12s %-14s %s${NC}\n" "PROFILE" "SCOPE" "SCHEDULE" "DEST" "RETENTION" "LAST RUN"
    local p scope cron dest ret enc last status
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        scope=$(_bk_profile_get "$p" scope)
        cron=$(_bk_profile_get "$p" cron)
        dest=$(_bk_profile_list_field "$p" destinations | paste -sd, -)
        ret=$(_bk_retention_label "$p")
        enc=$(_bk_profile_get "$p" encrypt)
        last=$(echo "$state" | jq -r --arg p "$p" '.[$p].last_end // "never"')
        status=$(echo "$state" | jq -r --arg p "$p" '.[$p].status // ""')
        local flag=""
        [[ "$(_bk_profile_get "$p" enabled)" == "false" ]] && flag=" ${DIM}(disabled)${NC}"
        [[ "$enc" == "true" ]] && dest="${dest}+enc"
        local col="$NC"
        [[ "$status" == "error" ]] && col="$RED"
        [[ "$status" == "ok" ]] && col="$GREEN"
        printf "  ${CYAN}%-16s${NC} %-6s %-15s %-12s %-14s ${col}%s${NC}%b\n" \
            "$p" "$scope" "$cron" "$dest" "$ret" "$last" "$flag"
    done <<< "$names"
    echo ""
    echo -e "  ${DIM}Details: cipi backup profile show <name>${NC}"
    echo ""
}

_bk_retention_label() {
    local p="$1" keep days weeks out=""
    keep=$(_bk_profiles_json | jq -r --arg p "$p" '.[$p].retention.keep // 0')
    days=$(_bk_profiles_json | jq -r --arg p "$p" '.[$p].retention.days // 0')
    weeks=$(_bk_profiles_json | jq -r --arg p "$p" '.[$p].retention.weeks // 0')
    [[ "$keep"  -gt 0 ]] && out="${out}${out:+,}${keep} runs"
    [[ "$days"  -gt 0 ]] && out="${out}${out:+,}${days}d"
    [[ "$weeks" -gt 0 ]] && out="${out}${out:+,}${weeks}w"
    echo "${out:-—}"
}

_bk_profile_created_label() {
    local ts
    ts=$(_bk_profiles_json | jq -r --arg p "$1" '.[$p].created_at // empty')
    [[ "$ts" =~ ^[0-9]+$ ]] || { echo "—"; return 0; }
    date -d "@${ts}" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "—"
}

_bk_profile_show() {
    local p="${1:-}"
    [[ -z "$p" ]] && { error "Usage: cipi backup profile show <name>"; exit 1; }
    _bk_require_config
    _bk_profile_exists "$p" || { error "No such profile: ${p}"; exit 1; }

    local state; state=$(_bk_state)
    echo -e "\n${BOLD}Backup profile '${p}'${NC}"
    printf "  %-20s %s\n" "Scope"        "$(_bk_profile_get "$p" scope)"
    printf "  %-20s %s\n" "Enabled"      "$(_bk_profile_get "$p" enabled)"
    printf "  %-20s %s\n" "Schedule"     "$(_bk_profile_get "$p" cron)"
    printf "  %-20s %s\n" "Apps"         "$(_bk_profile_list_field "$p" apps | paste -sd, -)"
    printf "  %-20s %s\n" "Databases"    "$(_bk_profile_list_field "$p" databases | paste -sd, -)"
    local exdb extbl
    exdb=$(_bk_profile_list_field "$p" exclude_databases | paste -sd, -)
    extbl=$(_bk_profile_list_field "$p" exclude_tables | paste -sd, -)
    printf "  %-20s %s\n" "Exclude DBs"    "${exdb:-—}"
    printf "  %-20s %s\n" "Exclude tables" "${extbl:-—}"
    printf "  %-20s %s\n" "Destinations" "$(_bk_profile_list_field "$p" destinations | paste -sd, -)"
    printf "  %-20s %s\n" "Encrypted"    "$(_bk_profile_get "$p" encrypt)"
    printf "  %-20s %s\n" "Created"      "$(_bk_profile_created_label "$p")"
    printf "  %-20s %s\n" "Retention"    "$(_bk_retention_label "$p")"
    echo ""
    echo -e "  ${BOLD}Last run${NC}"
    printf "  %-20s %s\n" "Started"  "$(echo "$state" | jq -r --arg p "$p" '.[$p].last_start // "never"')"
    printf "  %-20s %s\n" "Finished" "$(echo "$state" | jq -r --arg p "$p" '.[$p].last_end // "never"')"
    printf "  %-20s %s\n" "Status"   "$(echo "$state" | jq -r --arg p "$p" '.[$p].status // "—"')"
    printf "  %-20s %s\n" "Detail"   "$(echo "$state" | jq -r --arg p "$p" '.[$p].detail // "—"')"
    echo ""
    echo -e "  ${DIM}Preview what it would take: cipi backup run --profile=${p} --dry-run${NC}"
    echo ""
}

_bk_profile_toggle() {
    local p="$1" on="$2"
    [[ -z "$p" ]] && { error "Usage: cipi backup profile enable|disable <name>"; exit 1; }
    _bk_require_config
    _bk_profile_exists "$p" || { error "No such profile: ${p}"; exit 1; }
    _bk_cfg | jq --arg p "$p" --argjson v "$on" '.profiles[$p].enabled = $v' | _bk_cfg_write
    _bk_write_cron
    success "Profile '${p}' $([[ "$on" == "true" ]] && echo enabled || echo disabled)"
    log_action "BACKUP PROFILE $([[ "$on" == "true" ]] && echo ENABLE || echo DISABLE): $p"
}

_bk_profile_remove() {
    local p="${1:-}"
    [[ -z "$p" ]] && { error "Usage: cipi backup profile remove <name>"; exit 1; }
    _bk_require_config
    _bk_profile_exists "$p" || { error "No such profile: ${p}"; exit 1; }
    if [[ -t 0 ]]; then
        warn "Removing the profile does not delete the archives it already wrote."
        confirm "Remove backup profile '${p}'?" || { info "Cancelled"; return 0; }
    fi
    _bk_cfg | jq --arg p "$p" 'del(.profiles[$p])' | _bk_cfg_write
    _bk_state_write "$(_bk_state | jq --arg p "$p" 'del(.[$p])')"
    _bk_write_cron
    success "Profile '${p}' removed"
    log_action "BACKUP PROFILE REMOVE: $p"
}

# Comma-separated CLI value → JSON array (empty string → []).
_bk_csv_to_json() {
    local csv="${1:-}"
    [[ -z "$csv" ]] && { echo '[]'; return 0; }
    printf '%s' "$csv" | jq -R -s 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))'
}

_bk_profile_add() {
    local mode="$1"; shift||true
    local name="${1:-}"; shift||true
    [[ -z "$name" ]] && { error "Usage: cipi backup profile ${mode} <name> [flags]  (cipi help backup)"; exit 1; }
    _bk_valid_profile_name "$name" || { error "Invalid profile name '${name}' (lowercase letters, digits and dashes, 2-32 chars)"; exit 1; }
    _bk_require_config
    parse_args "$@"

    local existing="{}" is_new=true
    if _bk_profile_exists "$name"; then
        is_new=false
        existing=$(_bk_profile_json "$name")
        [[ "$mode" == "add" ]] && { error "Profile '${name}' already exists — use: cipi backup profile edit ${name} ..."; exit 1; }
    else
        [[ "$mode" == "edit" ]] && { error "No such profile: ${name}"; exit 1; }
        existing=$(_bk_default_profile_json)
    fi

    local json="$existing"

    # ── scope
    if [[ -n "${ARG_scope:-}" ]]; then
        case "${ARG_scope}" in
            all|files|db) json=$(echo "$json" | jq --arg v "${ARG_scope}" '.scope = $v') ;;
            *) error "--scope must be one of: all files db"; exit 1 ;;
        esac
    fi

    # ── selectors
    [[ -n "${ARG_apps:-}" ]] \
        && json=$(echo "$json" | jq --argjson v "$(_bk_csv_to_json "${ARG_apps}")" '.apps = $v')
    [[ -n "${ARG_databases:-}" ]] \
        && json=$(echo "$json" | jq --argjson v "$(_bk_csv_to_json "${ARG_databases}")" '.databases = $v')
    [[ -n "${ARG_exclude_databases:-}" ]] \
        && json=$(echo "$json" | jq --argjson v "$(_bk_csv_to_json "${ARG_exclude_databases}")" '.exclude_databases = $v')
    [[ -n "${ARG_exclude_tables:-}" ]] \
        && json=$(echo "$json" | jq --argjson v "$(_bk_csv_to_json "${ARG_exclude_tables}")" '.exclude_tables = $v')

    # ── schedule
    if [[ -n "${ARG_every:-}" && -n "${ARG_cron:-}" ]]; then
        error "Use either --every=<30m|6h|1d> or --cron='<expr>', not both"; exit 1
    fi
    if [[ -n "${ARG_every:-}" ]]; then
        local spec expr secs
        if ! spec=$(_bk_every_to_cron "${ARG_every}"); then
            error "Invalid --every='${ARG_every}'. Use Nm (a divisor of 60), Nh (a divisor of 24) or Nd (1-28)."
            exit 1
        fi
        secs="${spec%%$'\t'*}"; expr="${spec#*$'\t'}"
        json=$(echo "$json" | jq --arg c "$expr" --argjson i "$secs" '.cron = $c | .interval_seconds = $i')
    elif [[ -n "${ARG_cron:-}" ]]; then
        _bk_valid_cron "${ARG_cron}" || { error "Invalid --cron expression (5 fields, digits and * / , - only)"; exit 1; }
        local secs; secs=$(_bk_cron_interval_seconds "${ARG_cron}")
        json=$(echo "$json" | jq --arg c "${ARG_cron}" --argjson i "$secs" '.cron = $c | .interval_seconds = $i')
    fi

    # ── destinations
    if [[ -n "${ARG_dest:-}" ]]; then
        local d dests="[]"
        dests=$(_bk_csv_to_json "${ARG_dest}")
        while IFS= read -r d; do
            [[ -n "$d" ]] || continue
            case "$d" in
                local) ;;
                s3) _bk_has_s3 || { error "--dest=s3 but no bucket configured. Run: cipi backup configure"; exit 1; } ;;
                *) error "--dest must be 'local', 's3' or 'local,s3'"; exit 1 ;;
            esac
        done < <(echo "$dests" | jq -r '.[]')
        [[ "$(echo "$dests" | jq 'length')" -eq 0 ]] && { error "--dest cannot be empty"; exit 1; }
        json=$(echo "$json" | jq --argjson v "$dests" '.destinations = $v')
    fi

    # ── retention
    local touched_ret=false
    for k in keep keep_days keep_weeks; do
        local var="ARG_${k}"
        [[ -n "${!var:-}" ]] && touched_ret=true
    done
    if [[ "$touched_ret" == true ]]; then
        local keep="${ARG_keep:-0}" days="${ARG_keep_days:-0}" weeks="${ARG_keep_weeks:-0}"
        for v in "$keep" "$days" "$weeks"; do
            [[ "$v" =~ ^[0-9]+$ ]] || { error "Retention values must be non-negative integers"; exit 1; }
        done
        if [[ "$keep" -eq 0 && "$days" -eq 0 && "$weeks" -eq 0 ]]; then
            error "At least one of --keep, --keep-days, --keep-weeks must be greater than 0"
            error "A profile with no retention would grow without bound."
            exit 1
        fi
        json=$(echo "$json" | jq \
            --argjson k "$keep" --argjson d "$days" --argjson w "$weeks" \
            '.retention = {keep: $k, days: $d, weeks: $w}')
    fi

    # ── encryption
    if [[ "${ARG_encrypt:-}" == "true" ]]; then
        _bk_key_ensure || { error "Could not create the backup encryption key"; exit 1; }
        json=$(echo "$json" | jq '.encrypt = true')
    elif [[ "${ARG_no_encrypt:-}" == "true" ]]; then
        json=$(echo "$json" | jq '.encrypt = false')
    fi

    # ── coherence checks
    local scope; scope=$(echo "$json" | jq -r '.scope')
    if [[ "$scope" == "files" ]] && [[ "$(echo "$json" | jq '.apps | length')" -eq 0 ]]; then
        error "--scope=files with an empty --apps list would back up nothing"; exit 1
    fi
    if [[ "$scope" == "db" ]] && [[ "$(echo "$json" | jq '.databases | length')" -eq 0 ]]; then
        error "--scope=db with an empty --databases list would back up nothing"; exit 1
    fi
    if [[ "$(echo "$json" | jq '.destinations | length')" -eq 0 ]]; then
        error "Profile has no destination — set --dest=local and/or --dest=s3"; exit 1
    fi

    _bk_profile_save "$name" "$json"
    if [[ "$is_new" == true ]]; then
        success "Backup profile '${name}' created"
        log_action "BACKUP PROFILE ADD: $name"
    else
        success "Backup profile '${name}' updated"
        log_action "BACKUP PROFILE EDIT: $name"
    fi
    if [[ "$(echo "$json" | jq -r '.encrypt')" == "true" ]]; then
        warn "Archives are encrypted — save the key now: cipi backup key show"
    fi
    _bk_profile_show "$name"
}

# ── Crontab (single managed block) ───────────────────────────
#
# The schedule is derived from the profiles and rewritten wholesale between
# markers, so editing a profile is enough — nobody has to hand-edit crontab,
# and Cipi never touches lines outside its own block.

_BK_CRON_START="# === CIPI BACKUP START (managed by 'cipi backup profile' — do not edit by hand) ==="
_BK_CRON_END="# === CIPI BACKUP END ==="

_bk_write_cron() {
    [[ $EUID -ne 0 ]] && return 0
    local current block=""
    current=$(crontab -l 2>/dev/null || true)

    # Drop the managed block and any pre-5.1 unmanaged backup lines.
    current=$(printf '%s\n' "$current" | awk -v s="$_BK_CRON_START" -v e="$_BK_CRON_END" '
        $0 == s { skip = 1; next }
        $0 == e { skip = 0; next }
        skip { next }
        /^# === CIPI BACKUP \(all apps\) ===$/ { next }
        /cipi backup run/ { next }
        /cipi backup prune/ { next }
        /cipi backup check/ { next }
        { print }
    ')

    local p cron enabled
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        enabled=$(_bk_profile_get "$p" enabled)
        [[ "$enabled" == "false" ]] && continue
        cron=$(_bk_profile_get "$p" cron)
        _bk_valid_cron "$cron" || continue
        block="${block}${cron} /usr/local/bin/cipi backup run --profile=${p} >> ${CIPI_LOG}/backup.log 2>&1"$'\n'
    done < <(_bk_profile_names)

    # Overdue-backup watchdog: a backup that silently stops running is worse
    # than no backup, because it still looks configured.
    if [[ -n "$block" ]]; then
        block="${block}17 * * * * /usr/local/bin/cipi backup check --quiet >> ${CIPI_LOG}/backup.log 2>&1"$'\n'
    fi

    {
        [[ -n "$current" ]] && printf '%s\n' "$current"
        if [[ -n "$block" ]]; then
            printf '%s\n' "$_BK_CRON_START"
            printf '%s' "$block"
            printf '%s\n' "$_BK_CRON_END"
        fi
    } | crontab -
}

# ── Run state (last result per profile) ──────────────────────

_bk_state()       { vault_read backup-state.json 2>/dev/null || echo '{}'; }
_bk_state_write() { printf '%s' "$1" | vault_write backup-state.json; }

_bk_state_set() {
    local profile="$1" status="$2" detail="$3" started="$4"
    local st; st=$(_bk_state)
    _bk_state_write "$(echo "$st" | jq \
        --arg p "$profile" --arg s "$status" --arg d "$detail" \
        --arg b "$started" --arg e "$(date '+%Y-%m-%d %H:%M:%S')" \
        --argjson ts "$(date +%s)" '
        .[$p] = ((.[$p] // {}) + {
            last_start: $b, last_end: $e, status: $s, detail: $d, last_epoch: $ts
        })
        | if $s == "ok" then .[$p].last_success_epoch = $ts else . end
    ')"
}

# ── Selection ────────────────────────────────────────────────

# Apps a profile covers (registered in apps.json, matching its globs).
_bk_select_apps() {
    local p="$1" globs a
    globs=$(_bk_profile_list_field "$p" apps)
    while IFS= read -r a; do
        [[ -n "$a" ]] || continue
        _bk_glob_match "$a" "$globs" && echo "$a"
    done < <(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
}

# Databases a profile covers, as "<engine>\t<name>" lines.
#
# The list comes from the *engine*, not from databases.json: tenant databases
# a multi-tenant app creates at runtime appear in no registry, and a backup
# that only consulted the registry skipped every one of them.
_bk_select_databases() {
    local p="$1" inc exc eng db
    inc=$(_bk_profile_list_field "$p" databases)
    exc=$(_bk_profile_list_field "$p" exclude_databases)

    for eng in mariadb pgsql; do
        db_engine_is_installed "$eng" 2>/dev/null || continue
        while IFS= read -r db; do
            [[ -n "$db" ]] || continue
            _bk_glob_match "$db" "$inc" || continue
            _bk_glob_match "$db" "$exc" && continue
            printf '%s\t%s\n' "$eng" "$db"
        done < <(db_list_databases "$eng" 2>/dev/null || true)
    done
}

# Paths to archive for an app, relative to /home/<app>.
#
# Laravel apps keep everything durable in shared/ (the .env and storage/); the
# code itself comes back from git. A --custom app has no shared/ at all — its
# files live in htdocs/, and archiving shared/ there failed on every run,
# marking the whole backup as errored while quietly saving nothing.
_bk_app_home() { echo "/home/${1:-}"; }

_bk_app_paths() {
    local app="$1"
    local home
    home=$(_bk_app_home "$app")
    if [[ "$(app_get "$app" runtime)" == "node" ]]; then
        # Code comes back from git; shared/ holds .env.
        [[ -d "${home}/shared" ]] && echo "shared"
    elif [[ "$(app_get "$app" custom)" == "true" ]]; then
        [[ -d "${home}/htdocs" ]] && echo "htdocs"
    else
        [[ -d "${home}/shared" ]] && echo "shared"
    fi
    # "nothing to archive" is a normal answer, not a failure: without this the
    # empty result made the assignment fail and `set -e` aborted the whole
    # backup run before it reached the "skipped" warning.
    return 0
}

# Is this gzip stream complete and readable? Catches the failure mode that
# matters most here — an archive truncated by a full disk, which is non-empty
# and therefore passes every size check, but restores to nothing.
_bk_check_archive() {
    local f="$1"
    [[ -s "$f" ]] || return 1
    gzip -t "$f" 2>/dev/null
}

# ── Run ──────────────────────────────────────────────────────

_bk_run() {
    local profile="" target="" dry=false
    local arg
    for arg in "$@"; do
        case "$arg" in
            --profile=*) profile="${arg#--profile=}" ;;
            --dry-run)   dry=true ;;
            --*)         error "Unknown flag: ${arg}"; exit 1 ;;
            *)           target="$arg" ;;
        esac
    done

    _bk_require_config
    _bk_ensure_default_profile

    # `cipi backup run` / `cipi backup run <app>` keep their old meaning: run
    # every enabled profile (optionally narrowed to one app).
    if [[ -z "$profile" ]]; then
        local any=false p rc=0
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            [[ "$(_bk_profile_get "$p" enabled)" == "false" ]] && continue
            any=true
            # One failing profile must not stop the others, and must not let
            # `set -e` kill the whole run — but the exit code still reports it.
            _bk_run_profile "$p" "$target" "$dry" || rc=1
        done < <(_bk_profile_names)
        [[ "$any" == false ]] && { warn "No enabled backup profiles"; return 0; }
        return "$rc"
    fi

    _bk_profile_exists "$profile" || { error "No such profile: ${profile}"; exit 1; }
    _bk_run_profile "$profile" "$target" "$dry"
}

_bk_run_profile() {
    local p="$1" only_app="${2:-}" dry="${3:-false}"

    # Guarded: _bk_run loops over every profile, and re-sourcing on each pass
    # is pure waste.
    # shellcheck source=/dev/null
    declare -f db_dump_database_ex >/dev/null 2>&1 || source "${CIPI_LIB}/db.sh"

    local scope encrypt dests ts started
    scope=$(_bk_profile_get "$p" scope)
    encrypt=$(_bk_profile_get "$p" encrypt)
    dests=$(_bk_profile_list_field "$p" destinations)
    ts=$(date +%Y-%m-%d_%H%M%S)
    started=$(date '+%Y-%m-%d %H:%M:%S')

    echo -e "\n${BOLD}Backup profile '${p}'${NC} ${DIM}(${scope}, ${ts})${NC}"

    local -a apps=() dbs=()
    if [[ "$scope" == "all" || "$scope" == "files" ]]; then
        while IFS= read -r a; do
            [[ -n "$a" ]] || continue
            [[ -n "$only_app" && "$a" != "$only_app" ]] && continue
            apps+=("$a")
        done < <(_bk_select_apps "$p")
    fi
    if [[ "$scope" == "all" || "$scope" == "db" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            dbs+=("$line")
        done < <(_bk_select_databases "$p")
    fi

    if [[ "$dry" == true ]]; then
        echo -e "  ${BOLD}Would archive files for ${#apps[@]} app(s):${NC}"
        local a
        for a in "${apps[@]:-}"; do
            [[ -n "$a" ]] || continue
            echo -e "    ${CYAN}${a}${NC} ${DIM}($(_bk_app_paths "$a" | paste -sd, - || echo 'nothing to archive'))${NC}"
        done
        echo -e "  ${BOLD}Would dump ${#dbs[@]} database(s):${NC}"
        local l
        for l in "${dbs[@]:-}"; do
            [[ -n "$l" ]] || continue
            echo -e "    ${CYAN}$(echo "$l" | cut -f2)${NC} ${DIM}($(echo "$l" | cut -f1))${NC}"
        done
        echo -e "  ${BOLD}Destinations:${NC} $(echo "$dests" | paste -sd, -)$([[ "$encrypt" == "true" ]] && echo " (encrypted)")"
        echo ""
        return 0
    fi

    if [[ ${#apps[@]} -eq 0 && ${#dbs[@]} -eq 0 ]]; then
        warn "Profile '${p}' matched nothing — check its apps/databases patterns"
        _bk_state_set "$p" "warn" "matched nothing" "$started"
        return 0
    fi

    local tmp; tmp="$(_bk_tmp_base)/cipi-bk-${p}-${ts}"
    mkdir -p "${tmp}/apps" "${tmp}/databases"
    local errors=""

    # ── application files
    local a paths tar_err
    for a in "${apps[@]:-}"; do
        [[ -n "$a" ]] || continue
        paths=$(_bk_app_paths "$a")
        if [[ -z "$paths" ]]; then
            warn "  ${a}: nothing to archive (no shared/ or htdocs/) — skipped"
            continue
        fi
        step "  Files: ${a} (${paths//$'\n'/, })"
        mkdir -p "${tmp}/apps/${a}"
        # tar exits 1 for *warnings* — most commonly "file changed as we read
        # it", which happens constantly on a live app writing its logs. Only
        # exit 2 and above means the archive is unusable; treating 1 as failure
        # would flag a perfectly good backup as broken on every busy site.
        local tar_rc=0
        # shellcheck disable=SC2086
        tar_err=$(tar -czf "${tmp}/apps/${a}/files.tar.gz" -C "$(_bk_app_home "$a")" $paths 2>&1) || tar_rc=$?
        if [[ $tar_rc -ge 2 ]]; then
            error "    archive failed: ${tar_err}"
            errors="${errors}${errors:+, }files:${a}"
            rm -f "${tmp}/apps/${a}/files.tar.gz"
            continue
        elif [[ $tar_rc -eq 1 ]]; then
            warn "    files changed while being archived (normal on a live app)"
        fi
        if ! _bk_check_archive "${tmp}/apps/${a}/files.tar.gz"; then
            error "    archive is unreadable — discarding it rather than storing a corrupt backup"
            errors="${errors}${errors:+, }files:${a}"
            rm -f "${tmp}/apps/${a}/files.tar.gz"
            continue
        fi
        vault_read apps.json | jq --arg a "$a" '.[$a] | {
            domain, aliases, php, branch, repository, custom, docroot, engine,
            octane, reverb, horizon, schedule
        }' > "${tmp}/apps/${a}/meta.json" 2>/dev/null || echo '{}' > "${tmp}/apps/${a}/meta.json"
    done

    # ── databases
    local excl_tables line eng db
    excl_tables=$(_bk_profile_list_field "$p" exclude_tables | paste -sd, -)
    for line in "${dbs[@]:-}"; do
        [[ -n "$line" ]] || continue
        eng=$(echo "$line" | cut -f1); db=$(echo "$line" | cut -f2)
        step "  Database: ${db} (${eng})"
        mkdir -p "${tmp}/databases/${eng}"
        if ! db_dump_database_ex "$eng" "$db" "${tmp}/databases/${eng}/${db}.sql.gz" "$excl_tables" 2>/dev/null; then
            error "    dump failed: ${db} (${eng})"
            errors="${errors}${errors:+, }db:${db}"
            rm -f "${tmp}/databases/${eng}/${db}.sql.gz"
        elif ! _bk_check_archive "${tmp}/databases/${eng}/${db}.sql.gz"; then
            # A dump truncated by a full disk is still a non-empty file, so the
            # size check inside db_dump_database_ex cannot catch it. Storing it
            # would be worse than failing: it looks like a backup and is not.
            error "    dump is truncated or corrupt (disk full?) — discarding it"
            errors="${errors}${errors:+, }db:${db}"
            rm -f "${tmp}/databases/${eng}/${db}.sql.gz"
        fi
    done

    # ── manifest
    jq -n \
        --arg p "$p" --arg ts "$ts" --arg scope "$scope" \
        --arg host "$(hostname)" --arg ver "${CIPI_VERSION:-unknown}" \
        --argjson enc "$([[ "$encrypt" == "true" ]] && echo true || echo false)" \
        --argjson apps "$(printf '%s\n' "${apps[@]:-}" | jq -R -s 'split("\n")|map(select(length>0))')" \
        --argjson dbs "$(printf '%s\n' "${dbs[@]:-}" | jq -R -s 'split("\n")|map(select(length>0))|map(split("\t")|{engine:.[0],name:.[1]})')" \
        '{profile:$p, timestamp:$ts, scope:$scope, host:$host, cipi:$ver, encrypted:$enc, apps:$apps, databases:$dbs}' \
        > "${tmp}/manifest.json"

    # ── encrypt in place (manifest stays readable so a run can be identified)
    if [[ "$encrypt" == "true" ]]; then
        step "  Encrypting archives..."
        local f
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            if _bk_encrypt_file "$f" "${f}.enc"; then
                rm -f "$f"
            else
                error "    encryption failed: $(basename "$f")"
                errors="${errors}${errors:+, }encrypt:$(basename "$f")"
            fi
        done < <(find "$tmp" -type f \( -name '*.tar.gz' -o -name '*.sql.gz' \) 2>/dev/null)
    fi

    # ── ship
    local dest
    while IFS= read -r dest; do
        [[ -n "$dest" ]] || continue
        case "$dest" in
            local)
                local ldir; ldir="$(_bk_local_root)/${p}/${ts}"
                mkdir -p "$ldir"
                if cp -a "${tmp}/." "$ldir/" 2>/dev/null; then
                    chmod -R go-rwx "$(_bk_local_root)" 2>/dev/null || true
                    success "  → ${ldir}"
                else
                    error "  local copy failed: ${ldir}"
                    errors="${errors}${errors:+, }dest:local"
                fi
                ;;
            s3)
                _ensure_awscli
                local bucket; bucket=$(_bk_s3_bucket)
                if [[ -z "$bucket" ]]; then
                    error "  no S3 bucket configured"
                    errors="${errors}${errors:+, }dest:s3"
                    continue
                fi
                local s3_err
                if ! s3_err=$(_aws_s3 cp "${tmp}/" "s3://${bucket}/cipi/${p}/${ts}/" --recursive 2>&1); then
                    error "  S3 upload failed:"
                    echo "$s3_err" | sed 's/^/    /'
                    errors="${errors}${errors:+, }dest:s3"
                else
                    success "  → s3://${bucket}/cipi/${p}/${ts}/"
                fi
                ;;
        esac
    done <<< "$dests"

    rm -rf "$tmp"

    if [[ -n "$errors" ]]; then
        _bk_state_set "$p" "error" "$errors" "$started"
        error "Backup '${p}' completed with errors: ${errors}"
        cipi_notify \
            "Cipi backup failed: profile ${p} on $(hostname)" \
            "Backup profile '${p}' finished with errors.\n\nServer: $(hostname)\nProfile: ${p}\nRun: ${ts}\nFailed: ${errors}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')\n\nLog: ${CIPI_LOG}/backup.log" \
            backup_fail
        log_action "BACKUP ERROR: profile=${p} run=${ts} ${errors}"
        _bk_retention_after_run "$p"
        return 1
    fi

    _bk_state_set "$p" "ok" "${#apps[@]} app(s), ${#dbs[@]} database(s)" "$started"
    success "Backup '${p}' complete — ${#apps[@]} app(s), ${#dbs[@]} database(s)"
    log_action "BACKUP OK: profile=${p} run=${ts} apps=${#apps[@]} dbs=${#dbs[@]}"
    _bk_retention_after_run "$p"
    return 0
}

# ── Prune ────────────────────────────────────────────────────

_bk_prune() {
    _bk_require_config
    local profile="" weeks="" target="" dry=false arg
    for arg in "$@"; do
        case "$arg" in
            --profile=*) profile="${arg#--profile=}" ;;
            --weeks=*)   weeks="${arg#--weeks=}" ;;
            --dry-run)   dry=true ;;
            --*)         error "Unknown flag: ${arg}"; exit 1 ;;
            *)           target="$arg" ;;
        esac
    done

    # Legacy form: `cipi backup prune [app] --weeks=N` over the pre-5.1 layout.
    if [[ -n "$weeks" ]]; then
        _bk_prune_legacy "$target" "$weeks"
        return $?
    fi

    _BK_PRUNE_ERRORS=""
    if [[ -n "$profile" ]]; then
        _bk_profile_exists "$profile" || { error "No such profile: ${profile}"; exit 1; }
        _bk_prune_profile "$profile" "$dry"
    else
        local p
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            _bk_prune_profile "$p" "$dry"
        done < <(_bk_profile_names)
    fi
    _bk_prune_orphans "$dry"
    if [[ -n "$_BK_PRUNE_ERRORS" ]]; then
        error "Retention incomplete: ${_BK_PRUNE_ERRORS}"
        return 1
    fi
    return 0
}

# Decide which run timestamps of a profile must go, then delete them from
# every destination. Retention is per profile: a 30-minute database profile
# keeping 48 runs coexists with a weekly full profile keeping 8 weeks.
_bk_prune_profile() {
    local p="$1" dry="${2:-false}"
    local keep days weeks
    keep=$(_bk_profiles_json  | jq -r --arg p "$p" '.[$p].retention.keep  // 0')
    days=$(_bk_profiles_json  | jq -r --arg p "$p" '.[$p].retention.days  // 0')
    weeks=$(_bk_profiles_json | jq -r --arg p "$p" '.[$p].retention.weeks // 0')
    [[ "$keep" -eq 0 && "$days" -eq 0 && "$weeks" -eq 0 ]] && return 0

    local cutoff=0 total_days=0
    [[ "$days"  -gt 0 ]] && total_days=$days
    [[ "$weeks" -gt 0 ]] && total_days=$(( total_days + weeks * 7 ))
    if [[ "$total_days" -gt 0 ]]; then
        cutoff=$(date -d "${total_days} days ago" +%s 2>/dev/null || date -v "-${total_days}d" +%s)
    fi

    # Union of run timestamps across destinations, newest first. A destination
    # that cannot be listed would make this prune nothing, silently, forever:
    # say so (the caller turns it into an alert).
    local errf runs
    errf=$(mktemp)
    runs=$(_bk_list_runs "$p" 2>"$errf" | sort -r | awk '!seen[$0]++')
    if [[ -s "$errf" ]]; then
        _BK_PRUNE_ERRORS="${_BK_PRUNE_ERRORS:-}${_BK_PRUNE_ERRORS:+; }${p}: $(paste -sd' ' "$errf")"
        warn "  Retention for '${p}' is incomplete — $(paste -sd' ' "$errf")"
    fi
    rm -f "$errf"
    [[ -z "$runs" ]] && return 0

    local idx=0 ts run_epoch drop
    while IFS= read -r ts; do
        [[ -n "$ts" ]] || continue
        ((idx++)) || true
        drop=false

        # Age rule
        if [[ "$cutoff" -gt 0 ]]; then
            local date_part="${ts%%_*}"
            run_epoch=$(date -d "$date_part" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$date_part" +%s 2>/dev/null || echo 0)
            [[ "$run_epoch" -gt 0 && "$run_epoch" -lt "$cutoff" ]] && drop=true
        fi
        # Count rule — never drops a run that the count rule still wants.
        if [[ "$keep" -gt 0 ]]; then
            if [[ "$idx" -le "$keep" ]]; then drop=false
            elif [[ "$cutoff" -eq 0 ]]; then drop=true
            fi
        fi

        [[ "$drop" == true ]] || continue
        if [[ "$dry" == true ]]; then
            echo -e "  ${DIM}would delete${NC} ${p}/${ts}"
            continue
        fi
        _bk_delete_run "$p" "$ts"
    done <<< "$runs"
}

# Run timestamps that exist for a profile, on any destination.
_bk_list_runs() {
    local p="$1"
    local ldir; ldir="$(_bk_local_root)/${p}"
    [[ -d "$ldir" ]] && ls -1 "$ldir" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' || true
    if _bk_has_s3; then
        _bk_s3_ls_dirs "s3://$(_bk_s3_bucket)/cipi/${p}/" \
            | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' || true
    fi
}

# Sub-"directories" of an S3 prefix, one per line. An empty or missing prefix
# is not an error (aws exits 1 with nothing on stderr); anything else — no CLI,
# denied ListBucket, a wrong endpoint — is reported on stderr.
_bk_s3_ls_dirs() {
    local uri="$1" out errf rc=0
    if ! command -v aws &>/dev/null; then
        echo "AWS CLI not found — S3 archives cannot be listed" >&2
        return 1
    fi
    errf=$(mktemp)
    out=$(_aws_s3 ls "$uri" 2>"$errf") || rc=$?
    if [[ $rc -ne 0 && -s "$errf" ]]; then
        echo "cannot list ${uri}: $(grep -v '^[[:space:]]*$' "$errf" | tail -1)" >&2
        rm -f "$errf"
        return 1
    fi
    rm -f "$errf"
    printf '%s\n' "$out" | awk '$1 == "PRE" {print $2}' | sed 's#/$##'
}

_bk_delete_run() {
    local p="$1" ts="$2"
    local ldir="$(_bk_local_root)/${p}/${ts}"
    if [[ -d "$ldir" ]]; then
        rm -rf "$ldir"
        step "  Deleted local: ${p}/${ts}"
    fi
    if _bk_has_s3 && command -v aws &>/dev/null; then
        local bucket; bucket=$(_bk_s3_bucket)
        if _aws_s3 ls "s3://${bucket}/cipi/${p}/${ts}/" &>/dev/null; then
            local rm_err
            if rm_err=$(_aws_s3 rm "s3://${bucket}/cipi/${p}/${ts}/" --recursive 2>&1 >/dev/null); then
                step "  Deleted S3:    ${p}/${ts}"
            else
                error "  S3 delete failed: ${p}/${ts} — $(tail -1 <<< "$rm_err")"
                _BK_PRUNE_ERRORS="${_BK_PRUNE_ERRORS:-}${_BK_PRUNE_ERRORS:+; }${p}/${ts}: delete failed"
            fi
        fi
    fi
}

# ── Orphaned archives ────────────────────────────────────────
#
# Archives no profile prunes any more, which used to pile up forever:
#   * the pre-5.1 layout, s3://<bucket>/cipi/<app>/<date…>/ — 5.1.0 turned the
#     nightly job into the `default` profile and dropped the old
#     `cipi backup prune --weeks=N` line that was their only cleanup;
#   * <local_dir>/<name>/ and s3://<bucket>/cipi/<name>/ of a profile that was
#     removed (removing a profile keeps its archives);
#   * database dumps in /var/log/cipi/backups/ — pre-deploy snapshots
#     (cipi deploy --snapshot) still land there.
# They are kept as long as the longest age-based retention of any profile, so
# nothing goes sooner than a current profile would keep it. With only count
# retention (keep: N) there is no age to go by, and they are left alone.

_bk_orphan_retention_days() {
    _bk_profiles_json | jq -r '[.[] | ((.retention.days // 0) + (.retention.weeks // 0) * 7)] | max // 0' 2>/dev/null || echo 0
}

_bk_date_epoch() {
    date -d "$1" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$1" +%s 2>/dev/null || echo 0
}

# $1 = dry (true|false)
_bk_prune_orphans() {
    local dry="${1:-false}" days cutoff profiles name ts dp ep f
    days=$(_bk_orphan_retention_days)
    [[ "$days" =~ ^[0-9]+$ && "$days" -gt 0 ]] || return 0
    cutoff=$(date -d "${days} days ago" +%s 2>/dev/null || date -v "-${days}d" +%s)
    profiles=$(_bk_profile_names)

    _orphan_old() { # $1 = folder name → 0 when it is a dated run older than the cutoff
        [[ "$1" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}) ]] || return 1
        ep=$(_bk_date_epoch "${BASH_REMATCH[1]}")
        [[ "$ep" -gt 0 && "$ep" -lt "$cutoff" ]]
    }

    # local: removed profiles
    local lroot; lroot=$(_bk_local_root)
    if [[ -d "$lroot" ]]; then
        for dp in "$lroot"/*/; do
            [[ -d "$dp" ]] || continue
            name=$(basename "$dp")
            grep -Fxq "$name" <<< "$profiles" && continue
            for f in "$dp"*/; do
                [[ -d "$f" ]] || continue
                ts=$(basename "$f")
                _orphan_old "$ts" || continue
                if [[ "$dry" == true ]]; then echo -e "  ${DIM}would delete${NC} local ${name}/${ts} (orphaned)"; continue; fi
                rm -rf "$f" && step "  Deleted local: ${name}/${ts} (orphaned)"
            done
            [[ "$dry" == true ]] || rmdir "$dp" 2>/dev/null || true
        done
    fi

    # local: loose dumps (pre-5.1 layout, pre-deploy snapshots)
    for f in "${CIPI_LOG}/backups/"*.sql.gz; do
        [[ -f "$f" ]] || continue
        # <engine>_<app>_predeploy_YYYYMMDD_HHMMSS.sql.gz — the date is the
        # suffix; an app name may contain digits of its own.
        [[ "$(basename "$f")" =~ ([0-9]{4})([0-9]{2})([0-9]{2})_[0-9]{6}\.sql\.gz$ ]] \
            || [[ "$(basename "$f")" =~ ([0-9]{4})([0-9]{2})([0-9]{2}) ]] || continue
        _orphan_old "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}" || continue
        if [[ "$dry" == true ]]; then echo -e "  ${DIM}would delete${NC} $(basename "$f")"; continue; fi
        rm -f "$f" && step "  Deleted local: $(basename "$f")"
    done

    # S3: prefixes under cipi/ that are not a profile
    _bk_has_s3 || return 0
    local bucket errf names runs
    bucket=$(_bk_s3_bucket)
    errf=$(mktemp)
    names=$(_bk_s3_ls_dirs "s3://${bucket}/cipi/" 2>"$errf") || true
    if [[ -s "$errf" ]]; then
        _BK_PRUNE_ERRORS="${_BK_PRUNE_ERRORS:-}${_BK_PRUNE_ERRORS:+; }orphans: $(paste -sd' ' "$errf")"
        warn "  Old archives could not be checked — $(paste -sd' ' "$errf")"
        rm -f "$errf"; return 0
    fi
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        grep -Fxq "$name" <<< "$profiles" && continue
        runs=$(_bk_s3_ls_dirs "s3://${bucket}/cipi/${name}/" 2>"$errf") || true
        if [[ -s "$errf" ]]; then
            _BK_PRUNE_ERRORS="${_BK_PRUNE_ERRORS:-}${_BK_PRUNE_ERRORS:+; }cipi/${name}: $(paste -sd' ' "$errf")"
            : > "$errf"; continue
        fi
        while IFS= read -r ts; do
            [[ -n "$ts" ]] || continue
            _orphan_old "$ts" || continue
            if [[ "$dry" == true ]]; then echo -e "  ${DIM}would delete${NC} s3 cipi/${name}/${ts} (orphaned)"; continue; fi
            local rm_err
            if rm_err=$(_aws_s3 rm "s3://${bucket}/cipi/${name}/${ts}/" --recursive 2>&1 >/dev/null); then
                step "  Deleted S3:    cipi/${name}/${ts} (orphaned)"
            else
                _BK_PRUNE_ERRORS="${_BK_PRUNE_ERRORS:-}${_BK_PRUNE_ERRORS:+; }cipi/${name}/${ts}: delete failed"
                error "  S3 delete failed: cipi/${name}/${ts} — $(tail -1 <<< "$rm_err")"
            fi
        done <<< "$runs"
    done <<< "$names"
    rm -f "$errf"
    unset -f _orphan_old
    return 0
}

# After a scheduled run: retention for the profile, orphans, and one alert when
# either could not do its job — a bucket that is never pruned only shows up on
# the invoice.
_bk_retention_after_run() {
    local p="$1"
    _BK_PRUNE_ERRORS=""
    _bk_prune_profile "$p" false || true
    _bk_prune_orphans false || true
    [[ -z "$_BK_PRUNE_ERRORS" ]] && return 0
    log_action "BACKUP PRUNE ERROR: profile=${p} ${_BK_PRUNE_ERRORS}"
    cipi_notify \
        "Cipi backup retention failed: profile ${p} on $(hostname)" \
        "Old backups could not be deleted, so they keep accumulating.\n\nServer: $(hostname)\nProfile: ${p}\nProblem: ${_BK_PRUNE_ERRORS}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')\n\nPreview what should go: cipi backup prune --dry-run" \
        backup_fail
}

# Pre-5.1 layout: s3://<bucket>/cipi/<app>/<ts>/ plus predeploy dumps in
# /var/log/cipi/backups. Kept so existing crontabs and archives still prune.
_bk_prune_legacy() {
    local target="$1" weeks="$2"
    [[ ! "$weeks" =~ ^[0-9]+$ ]] && { error "--weeks must be a positive integer"; exit 1; }
    [[ "$weeks" -eq 0 ]] && { error "--weeks must be greater than 0"; exit 1; }
    local cutoff; cutoff=$(date -d "${weeks} weeks ago" +%s 2>/dev/null || date -v "-${weeks}w" +%s)

    _prune_local() {
        local app="$1" found=0 f fname date_str file_ts
        for f in "${CIPI_LOG}/backups/${app}_"*.sql.gz "${CIPI_LOG}/backups/"*"_${app}_"*.sql.gz; do
            [[ -f "$f" ]] || continue
            fname=$(basename "$f")
            date_str=$(echo "$fname" | grep -oE '[0-9]{8}' | head -1)
            [[ -z "$date_str" ]] && continue
            file_ts=$(date -d "${date_str}" +%s 2>/dev/null || date -j -f "%Y%m%d" "${date_str}" +%s 2>/dev/null) || continue
            if [[ "$file_ts" -lt "$cutoff" ]]; then
                rm -f "$f"; step "  Deleted local: ${fname}"; found=1
            fi
        done
        [[ $found -eq 0 ]] && info "  No local dumps older than ${weeks} week(s) for '${app}'"
        return 0
    }

    _prune_s3_legacy() {
        local app="$1" found=0 folder date_str folder_ts
        _bk_has_s3 || { warn "S3 not configured — skipping S3 prune for '${app}'"; return; }
        _ensure_awscli
        local bucket; bucket=$(_bk_s3_bucket)
        while IFS= read -r folder; do
            folder=$(echo "$folder" | sed 's#/$##')
            [[ -z "$folder" ]] && continue
            date_str=$(echo "$folder" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}')
            [[ -z "$date_str" ]] && continue
            folder_ts=$(date -d "${date_str}" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "${date_str}" +%s 2>/dev/null) || continue
            if [[ "$folder_ts" -lt "$cutoff" ]]; then
                if _aws_s3 rm "s3://${bucket}/cipi/${app}/${folder}" --recursive &>/dev/null; then
                    step "  Deleted S3:   cipi/${app}/${folder}"; found=1
                else
                    error "  S3 delete failed for ${folder}"
                fi
            fi
        done < <(_aws_s3 ls "s3://${bucket}/cipi/${app}/" 2>/dev/null | awk '{print $NF}')
        [[ $found -eq 0 ]] && info "  No S3 backups older than ${weeks} week(s) for '${app}'"
        return 0
    }

    _prune_app_legacy() {
        local app="$1"
        echo -e "\n${BOLD}Pruning '${app}'${NC} ${DIM}(legacy layout, older than ${weeks} week(s))${NC}"
        _prune_local "$app"
        _prune_s3_legacy "$app"
    }

    if [[ -n "$target" ]]; then
        app_exists "$target" || { error "App not found: ${target}"; exit 1; }
        _prune_app_legacy "$target"
    else
        local apps a
        apps=$(vault_read apps.json | jq -r 'keys[]' 2>/dev/null) || true
        [[ -z "$apps" ]] && { warn "No apps found"; return 0; }
        while IFS= read -r a; do _prune_app_legacy "$a"; done <<< "$apps"
    fi
    echo ""
    success "Prune complete"
    log_action "backup prune (legacy)${target:+ $target} --weeks=${weeks}"
}

# ── List ─────────────────────────────────────────────────────

_bk_list() {
    _bk_require_config
    local profile="" arg
    for arg in "$@"; do
        case "$arg" in
            --profile=*) profile="${arg#--profile=}" ;;
            --*) error "Unknown flag: ${arg}"; exit 1 ;;
            *)   profile="$arg" ;;
        esac
    done

    local names
    if [[ -n "$profile" ]]; then
        _bk_profile_exists "$profile" || { error "No such profile: ${profile}"; exit 1; }
        names="$profile"
    else
        names=$(_bk_profile_names)
    fi

    local p ts n
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        echo -e "\n${BOLD}Backups — profile '${p}'${NC}"
        n=0
        while IFS= read -r ts; do
            [[ -n "$ts" ]] || continue
            ((n++)) || true
            local where=""
            [[ -d "$(_bk_local_root)/${p}/${ts}" ]] && where="local"
            if _bk_has_s3 && command -v aws &>/dev/null \
               && _aws_s3 ls "s3://$(_bk_s3_bucket)/cipi/${p}/${ts}/" &>/dev/null; then
                where="${where}${where:+,}s3"
            fi
            printf "  ${CYAN}%-22s${NC} %s\n" "$ts" "${where:-—}"
        done < <(_bk_list_runs "$p" | sort -r | awk '!seen[$0]++')
        [[ $n -eq 0 ]] && echo -e "  ${DIM}no runs yet${NC}"
    done <<< "$names"
    echo ""
    echo -e "  ${DIM}Download one: cipi backup fetch <profile> <timestamp>${NC}"
    echo ""
}

# ── Status / staleness ───────────────────────────────────────

_bk_status() {
    _bk_configured || {
        echo -e "\n${BOLD}Backup${NC}"
        echo -e "  ${YELLOW}Not configured${NC} — run: ${CYAN}cipi backup configure${NC}\n"
        return 0
    }
    local cfg; cfg=$(_bk_cfg)
    echo -e "\n${BOLD}Backup destinations${NC}"
    local bucket ep
    bucket=$(echo "$cfg" | jq -r '.bucket // ""')
    ep=$(echo "$cfg" | jq -r '.endpoint_url // ""')
    if [[ -n "$bucket" ]]; then
        printf "  %-14s ${GREEN}configured${NC}  s3://%s%s\n" "S3" "$bucket" "${ep:+  (${ep})}"
    else
        printf "  %-14s ${DIM}not configured${NC}\n" "S3"
    fi
    printf "  %-14s %s\n" "Local" "$(_bk_local_root)"
    if [[ -f "$BACKUP_KEY_FILE" ]]; then
        printf "  %-14s ${GREEN}present${NC}      %s\n" "Encryption key" "$BACKUP_KEY_FILE"
    else
        printf "  %-14s ${DIM}not created${NC}\n" "Encryption key"
    fi
    _bk_profile_list
    _bk_check_stale --report
}

# A profile that has not succeeded within twice its own interval is overdue.
# Run hourly from cron with --quiet: it only speaks up when something is wrong.
_bk_check_stale() {
    local quiet=false report=false arg
    for arg in "$@"; do
        case "$arg" in
            --quiet)  quiet=true ;;
            --report) report=true ;;
        esac
    done
    _bk_configured || return 0

    local state now p interval last grace overdue_list=""
    state=$(_bk_state); now=$(date +%s)

    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        [[ "$(_bk_profile_get "$p" enabled)" == "false" ]] && continue
        interval=$(_bk_profiles_json | jq -r --arg p "$p" '.[$p].interval_seconds // 86400')
        [[ "$interval" =~ ^[0-9]+$ ]] || interval=86400
        grace=$(( interval * 2 ))
        last=$(echo "$state" | jq -r --arg p "$p" '.[$p].last_success_epoch // 0')
        [[ "$last" =~ ^[0-9]+$ ]] || last=0

        if [[ "$last" -eq 0 ]]; then
            # A profile created five minutes ago has not yet "failed" to run a
            # nightly backup. Only complain once its first scheduled run should
            # plausibly have happened.
            local created
            created=$(_bk_profiles_json | jq -r --arg p "$p" '.[$p].created_at // 0')
            [[ "$created" =~ ^[0-9]+$ ]] || created=0
            if [[ "$created" -gt 0 && $(( now - created )) -lt "$grace" ]]; then
                continue
            fi
            overdue_list="${overdue_list}${overdue_list:+, }${p} (never succeeded)"
        elif [[ $(( now - last )) -gt "$grace" ]]; then
            overdue_list="${overdue_list}${overdue_list:+, }${p} (last success $(( (now - last) / 3600 ))h ago)"
        fi
    done < <(_bk_profile_names)

    if [[ -z "$overdue_list" ]]; then
        [[ "$quiet" == true ]] && return 0
        [[ "$report" == true ]] && echo -e "  ${GREEN}All profiles have run within their expected window.${NC}\n"
        [[ "$report" == false ]] && success "All backup profiles are up to date"
        return 0
    fi

    if [[ "$report" == true ]]; then
        echo -e "  ${YELLOW}Overdue:${NC} ${overdue_list}\n"
    else
        warn "Overdue backup profiles: ${overdue_list}"
    fi
    cipi_notify \
        "Cipi backup overdue on $(hostname)" \
        "One or more backup profiles have not completed successfully within their expected window.\n\nServer: $(hostname)\nOverdue: ${overdue_list}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')\n\nCheck: cipi backup status" \
        backup_stale
    return 0
}

# ── Verify ───────────────────────────────────────────────────
#
# An archive that cannot be opened is not a backup. Verify reads the newest run
# of each profile back and checks every member decompresses.

_bk_verify() {
    _bk_require_config
    local profile="" deep=false arg
    for arg in "$@"; do
        case "$arg" in
            --profile=*) profile="${arg#--profile=}" ;;
            --deep)      deep=true ;;
            --*) error "Unknown flag: ${arg}"; exit 1 ;;
            *)   profile="$arg" ;;
        esac
    done

    local names
    if [[ -n "$profile" ]]; then
        _bk_profile_exists "$profile" || { error "No such profile: ${profile}"; exit 1; }
        names="$profile"
    else
        names=$(_bk_profile_names)
    fi

    local failed=0 checked=0 p ts
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        ts=$(_bk_list_runs "$p" | sort -r | head -1)
        if [[ -z "$ts" ]]; then
            warn "Profile '${p}': no runs to verify yet"
            continue
        fi
        ((checked++)) || true
        echo -e "\n${BOLD}Verifying ${p}/${ts}${NC}"
        _bk_verify_run "$p" "$ts" "$deep" || failed=1
    done <<< "$names"
    echo ""
    if [[ $failed -ne 0 ]]; then
        error "Verification failed — see above"
        return 1
    fi
    if [[ $checked -eq 0 ]]; then
        # Saying "passed" after checking nothing is a false reassurance.
        warn "Nothing was verified — no profile has produced a backup yet."
        info "Take one now: cipi backup run"
        return 0
    fi
    success "Verification passed (${checked} profile(s))"
}

_bk_verify_run() {
    local p="$1" ts="$2" deep="$3"
    local dir="$(_bk_local_root)/${p}/${ts}" cleanup=""

    if [[ ! -d "$dir" ]]; then
        if [[ "$deep" != true ]]; then
            # No local copy: check the remote objects exist and are non-empty
            # without paying to download them.
            _bk_has_s3 || { error "  no local copy and no S3 configured"; return 1; }
            _ensure_awscli
            local listing
            listing=$(_aws_s3 ls "s3://$(_bk_s3_bucket)/cipi/${p}/${ts}/" --recursive 2>/dev/null || true)
            [[ -z "$listing" ]] && { error "  run not found on S3"; return 1; }
            local empty
            empty=$(echo "$listing" | awk '$3 == 0 {print $4}')
            if [[ -n "$empty" ]]; then
                error "  zero-byte objects:"; echo "$empty" | sed 's/^/    /'; return 1
            fi
            success "  $(echo "$listing" | wc -l) object(s) present on S3, none empty"
            info  "  Use --deep to download and decompress them"
            return 0
        fi
        _ensure_awscli
        dir="$(_bk_tmp_base)/cipi-verify-${p}-${ts}"
        cleanup="$dir"
        mkdir -p "$dir"
        step "  Downloading from S3..."
        _aws_s3 cp "s3://$(_bk_s3_bucket)/cipi/${p}/${ts}/" "$dir/" --recursive &>/dev/null \
            || { error "  download failed"; rm -rf "$cleanup"; return 1; }
    fi

    local rc=0 f name tmpf
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        name="${f#"${dir}/"}"
        tmpf=""
        if [[ "$f" == *.enc ]]; then
            tmpf=$(mktemp)
            if ! _bk_decrypt_file "$f" "$tmpf" 2>/dev/null; then
                error "  decrypt failed: ${name}"; rm -f "$tmpf"; rc=1; continue
            fi
            f="$tmpf"
        fi
        if [[ "$name" == *.tar.gz* ]]; then
            tar -tzf "$f" &>/dev/null && success "  ok: ${name}" || { error "  corrupt archive: ${name}"; rc=1; }
        elif [[ "$name" == *.sql.gz* ]]; then
            gzip -t "$f" &>/dev/null && success "  ok: ${name}" || { error "  corrupt dump: ${name}"; rc=1; }
        fi
        [[ -n "$tmpf" ]] && rm -f "$tmpf"
    done < <(find "$dir" -type f \( -name '*.tar.gz*' -o -name '*.sql.gz*' \) 2>/dev/null)

    [[ -n "$cleanup" ]] && rm -rf "$cleanup"
    return $rc
}

# ── Fetch ────────────────────────────────────────────────────
#
# Download (and decrypt) one run so it can be inspected or restored by hand.
# Restoring is deliberately manual: `cipi db restore` takes it from here.

_bk_fetch() {
    _bk_require_config
    local p="${1:-}" ts="${2:-}"; shift 2 2>/dev/null || true
    [[ -z "$p" || -z "$ts" ]] && { error "Usage: cipi backup fetch <profile> <timestamp> [--dest=<dir>]"; exit 1; }
    _bk_profile_exists "$p" || { error "No such profile: ${p}"; exit 1; }
    parse_args "$@"

    local dest="${ARG_dest:-$(_bk_tmp_base)/cipi-restore-${p}-${ts}}"
    mkdir -p "$dest" || { error "Cannot create ${dest}"; exit 1; }

    local src="$(_bk_local_root)/${p}/${ts}"
    if [[ -d "$src" ]]; then
        step "Copying local run ${p}/${ts}..."
        cp -a "${src}/." "${dest}/" || { error "Copy failed"; exit 1; }
    else
        _bk_has_s3 || { error "Run not found locally and no S3 configured"; exit 1; }
        _ensure_awscli
        step "Downloading s3://$(_bk_s3_bucket)/cipi/${p}/${ts}/ ..."
        _aws_s3 cp "s3://$(_bk_s3_bucket)/cipi/${p}/${ts}/" "${dest}/" --recursive &>/dev/null \
            || { error "Download failed — check the profile and timestamp (cipi backup list ${p})"; exit 1; }
    fi

    # `aws s3 cp --recursive` exits 0 when the prefix holds no objects, so a
    # wrong timestamp would otherwise be reported as a successful restore of an
    # empty directory. Never claim a backup is available without seeing it.
    if [[ -z "$(find "$dest" -type f -print -quit 2>/dev/null)" ]]; then
        rmdir "$dest" 2>/dev/null || true
        error "No backup found at ${p}/${ts} — nothing was downloaded."
        info "List what exists:  cipi backup list ${p}"
        exit 1
    fi
    if [[ ! -f "${dest}/manifest.json" ]]; then
        warn "This run has no manifest.json — it may be incomplete or from an older Cipi."
    fi

    local n=0 f
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        if _bk_decrypt_file "$f" "${f%.enc}" 2>/dev/null; then
            rm -f "$f"; ((n++)) || true
        else
            error "Could not decrypt $(basename "$f") — is ${BACKUP_KEY_FILE} the key it was written with?"
            exit 1
        fi
    done < <(find "$dest" -type f -name '*.enc' 2>/dev/null)
    [[ $n -gt 0 ]] && success "Decrypted ${n} file(s)"

    echo ""
    success "Backup available at: ${dest}"
    echo ""
    echo -e "  ${BOLD}Restore a database${NC}"
    echo -e "    ${CYAN}cipi db restore <name> ${dest}/databases/<engine>/<name>.sql.gz${NC}"
    echo -e "  ${BOLD}Inspect application files${NC}"
    echo -e "    ${CYAN}tar -tzf ${dest}/apps/<app>/files.tar.gz${NC}"
    echo ""
    warn "This directory holds decrypted data — delete it when you are done."
    echo ""
}

# ── Configure ────────────────────────────────────────────────

_bk_configure() {
    local cf="${CIPI_CONFIG}/backup.json"
    local ck="" cs="" cb="" cr="" ce="" ct="/var/tmp" cl=""
    if [[ -f "$cf" ]]; then
        local _bkj; _bkj=$(_bk_cfg)
        ck=$(echo "$_bkj" | jq -r '.aws_key    // ""')
        cs=$(echo "$_bkj" | jq -r '.aws_secret // ""')
        cb=$(echo "$_bkj" | jq -r '.bucket     // ""')
        cr=$(echo "$_bkj" | jq -r '.region     // ""')
        ce=$(echo "$_bkj" | jq -r '.endpoint_url // ""')
        ct=$(echo "$_bkj" | jq -r '.tmpdir // "/var/tmp"')
        cl=$(echo "$_bkj" | jq -r '.local_dir // ""')
    fi

    echo -e "\n${BOLD}Backup destination${NC}"
    echo -e "  ${DIM}Leave the bucket empty to keep backups on this server only.${NC}\n"

    read_input "Access Key ID" "$ck" ck
    read_input "Secret Access Key" "$cs" cs
    read_input "Bucket name (empty = local only)" "$cb" cb
    if [[ -n "$cb" ]]; then
        read_input "Region" "${cr:-eu-central-1}" cr
        echo -e "  ${DIM}Leave empty for AWS S3. For any other S3-compatible provider set the endpoint URL.${NC}"
        echo -e "  ${DIM}Examples:${NC}"
        echo -e "  ${DIM}  Cloudflare R2:  https://<account-id>.r2.cloudflarestorage.com${NC}"
        echo -e "  ${DIM}  Hetzner:        https://<datacenter>.your-objectstorage.com${NC}"
        echo -e "  ${DIM}  DO Spaces:      https://<region>.digitaloceanspaces.com${NC}"
        echo -e "  ${DIM}  Backblaze B2:   https://s3.<region>.backblazeb2.com${NC}"
        echo -e "  ${DIM}  Scaleway:       https://s3.<region>.scw.cloud${NC}"
        echo -e "  ${DIM}  MinIO:          https://your-minio-host${NC}"
        read_input "Endpoint URL (optional)" "$ce" ce
    fi
    echo -e "  ${DIM}Where local copies are kept (profiles with --dest=local).${NC}"
    read_input "Local backup directory" "${cl:-$BACKUP_DEFAULT_LOCAL}" cl
    echo -e "  ${DIM}Temp directory for backup archives (must have enough disk space; /tmp is often RAM-backed).${NC}"
    read_input "Temp directory" "$ct" ct

    # Region must not be empty — AWS CLI fails with "NoneType is not iterable" when region is blank
    cr="${cr:-eu-central-1}"
    ct="${ct:-/var/tmp}"
    cl="${cl:-$BACKUP_DEFAULT_LOCAL}"

    local existing_profiles; existing_profiles=$(_bk_profiles_json)
    jq -n \
        --arg k "$ck" --arg s "$cs" --arg b "$cb" \
        --arg r "$cr" --arg e "$ce" --arg t "$ct" --arg l "$cl" \
        --argjson p "$existing_profiles" \
        '{"aws_key":$k,"aws_secret":$s,"bucket":$b,"region":$r,"endpoint_url":$e,"tmpdir":$t,"local_dir":$l,"profiles":$p}' \
        | _bk_cfg_write

    mkdir -p "$cl" && chmod 700 "$cl" 2>/dev/null || true

    if [[ -n "$cb" ]]; then
        _ensure_awscli
        mkdir -p /root/.aws
        cat > /root/.aws/credentials <<AWSCREDS
[default]
aws_access_key_id = ${ck}
aws_secret_access_key = ${cs}
AWSCREDS
        cat > /root/.aws/config <<AWSCFG
[default]
region = ${cr}
output = json
AWSCFG
        chmod 600 /root/.aws/credentials /root/.aws/config

        step "Testing S3 connectivity..."
        local test_err
        if ! test_err=$(_aws_s3 ls "s3://${cb}" 2>&1); then
            error "S3 connection failed:"
            echo "$test_err" | sed 's/^/  /'
            exit 1
        fi
        success "S3 connection OK"
    else
        warn "No bucket configured — backups stay on this server only."
        warn "A local-only backup does not survive losing the server."
    fi

    _bk_ensure_default_profile
    _bk_write_cron
    success "Backup configured"
    echo ""
    echo -e "  ${DIM}The schedule is managed for you — no crontab editing needed.${NC}"
    echo -e "  ${DIM}Review it:            ${CYAN}cipi backup status${NC}"
    echo -e "  ${DIM}Add another strategy: ${CYAN}cipi backup profile add hourly-db --scope=db --every=30m --keep=48 --dest=local${NC}"
    echo ""
}
