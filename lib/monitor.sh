#!/bin/bash
#############################################
# Cipi — System monitor
#
# `cipi health` watches app URLs; `cipi monitor` watches the server itself:
# disk, certificate expiry, services, queue workers, 5xx spikes, read-only
# filesystems, load. Checks run every 5 minutes from /etc/cron.d/cipi-monitor
# and alert through cipi_notify (email + configured channels) on state
# transitions only: ok → warn/crit fires once, fail → ok sends a recovery,
# a persisting failure re-alerts every `reminder_minutes` (default 4h).
#############################################

[[ -z "${MONITOR_CFG:-}" ]]          && readonly MONITOR_CFG="${CIPI_CONFIG}/monitor.json"
[[ -z "${MONITOR_STATE_DIR:-}" ]]    && readonly MONITOR_STATE_DIR="${CIPI_LOG}/monitor"
[[ -z "${MONITOR_CRON:-}" ]]         && readonly MONITOR_CRON="/etc/cron.d/cipi-monitor"
[[ -z "${MONITOR_HELPER:-}" ]]       && readonly MONITOR_HELPER="/usr/local/bin/cipi-monitor"

# id|label — one per line, run order
_mon_catalog() {
    cat <<'EOF'
disk|Disk usage
ssl|SSL certificate expiry
services|System services
workers|Queue workers / Horizon
http_5xx|HTTP 5xx spike
fs|Filesystem read-only
load|Load average
EOF
}

_mon_known_check() {
    local id="${1:-}"
    _mon_catalog | cut -d'|' -f1 | grep -qx "$id"
}

_mon_check_label() {
    local id="${1:-}"
    _mon_catalog | awk -F'|' -v c="$id" '$1 == c { print $2; exit }'
}

# Keys that `cipi monitor set <check> --key=` accepts, per check.
_mon_settable_keys() {
    case "${1:-}" in
        disk)     echo "warn crit" ;;
        ssl)      echo "days" ;;
        http_5xx) echo "count ratio" ;;
        load)     echo "factor runs" ;;
        *)        echo "" ;;
    esac
}

_mon_default_config() {
    jq -n '{
        reminder_minutes: 240,
        checks: {
            disk:     {enabled: true, warn: 80, crit: 90},
            ssl:      {enabled: true, days: 14},
            services: {enabled: true},
            workers:  {enabled: true},
            http_5xx: {enabled: true, count: 20, ratio: 5},
            fs:       {enabled: true},
            load:     {enabled: true, factor: 4, runs: 2}
        }
    }'
}

_mon_ensure_config() {
    if [[ ! -f "$MONITOR_CFG" ]]; then
        _mon_default_config | vault_write monitor.json
    fi
}

_mon_cfg() {
    vault_read monitor.json 2>/dev/null || echo '{}'
}

_mon_check_enabled() {
    local id="$1"
    [[ ! -f "$MONITOR_CFG" ]] && return 0
    # NB: jq's `// true` treats false as empty — `!= false` is the correct
    # "default true" for an explicitly disabled check.
    [[ "$(_mon_cfg | jq -r --arg c "$id" '.checks[$c].enabled != false' 2>/dev/null)" == "true" ]]
}

_mon_cfg_val() {
    local id="$1" key="$2" default="$3"
    _mon_cfg | jq -r --arg c "$id" --arg k "$key" --arg d "$default" \
        '.checks[$c][$k] // $d' 2>/dev/null
}

_mon_reminder_sec() {
    local m
    m=$(_mon_cfg | jq -r '.reminder_minutes // 240' 2>/dev/null)
    [[ "$m" =~ ^[0-9]+$ ]] || m=240
    echo $(( m * 60 ))
}

# ── Checks ─────────────────────────────────────────────────────
# Contract: each prints one JSON object on stdout:
#   {"status":"ok|warn|crit", "summary":"one line", "detail":"alert body"}
# and always exits 0 — a broken check reports status "crit", it never
# crashes the runner (the cron helper runs under `set -euo pipefail`).

_mon_result() {
    local status="$1" summary="$2" detail="${3:-}"
    jq -n --arg s "$status" --arg m "$summary" --arg d "$detail" \
        '{status:$s, summary:$m, detail:$d}'
}

_mon_check_disk() {
    local warn crit
    warn=$(_mon_cfg_val disk warn 80);   [[ "$warn" =~ ^[0-9]+$ ]] || warn=80
    crit=$(_mon_cfg_val disk crit 90);   [[ "$crit" =~ ^[0-9]+$ ]] || crit=90
    local status=ok worst=0 detail="" line fs blocks used avail pct mount
    while read -r fs blocks used avail pct mount; do
        pct="${pct%\%}"
        [[ "$pct" =~ ^[0-9]+$ ]] || continue
        (( pct > worst )) && worst=$pct
        if (( pct >= crit )); then
            status=crit
            detail="${detail}${mount} at ${pct}% ($(df -Ph "$mount" 2>/dev/null | awk 'NR==2 {print $3" of "$2}'))\n"
        elif (( pct >= warn )); then
            [[ "$status" == "ok" ]] && status=warn
            detail="${detail}${mount} at ${pct}% ($(df -Ph "$mount" 2>/dev/null | awk 'NR==2 {print $3" of "$2}'))\n"
        fi
    done < <(df -Pl -x tmpfs -x devtmpfs -x overlay -x squashfs 2>/dev/null | awk 'NR>1')
    if [[ "$status" == "ok" ]]; then
        _mon_result ok "worst filesystem at ${worst}% (warn ${warn}%, crit ${crit}%)"
    else
        _mon_result "$status" "filesystem over threshold (worst ${worst}%)" "${detail%\\n}"
    fi
}

_mon_check_ssl() {
    local limit
    limit=$(_mon_cfg_val ssl days 14); [[ "$limit" =~ ^[0-9]+$ ]] || limit=14
    shopt -s nullglob
    local certs=(/etc/letsencrypt/live/*/cert.pem)
    shopt -u nullglob
    if [[ ${#certs[@]} -eq 0 ]]; then
        _mon_result ok "no Let's Encrypt certificates installed"
        return 0
    fi
    local now status=ok min_days=-1 detail="" cert name end end_ts left
    now=$(date +%s)
    for cert in "${certs[@]}"; do
        name=$(basename "$(dirname "$cert")")
        end=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2-)
        [[ -z "$end" ]] && continue
        end_ts=$(date -d "$end" +%s 2>/dev/null) || continue
        left=$(( (end_ts - now) / 86400 ))
        (( min_days < 0 || left < min_days )) && min_days=$left
        if (( left < 0 )); then
            status=crit
            detail="${detail}${name}: EXPIRED $(( -left )) day(s) ago\n"
        elif (( left <= limit )); then
            [[ "$status" == "ok" ]] && status=warn
            detail="${detail}${name}: expires in ${left} day(s)\n"
        fi
    done
    if [[ "$status" == "ok" ]]; then
        _mon_result ok "nearest expiry in ${min_days} days (limit ${limit})"
    else
        _mon_result "$status" "certificate expiry within ${limit} days" "${detail%\\n}"
    fi
}

_mon_check_services() {
    # Reuse the canonical service list from service.sh when available.
    if ! declare -f _resolve_services &>/dev/null; then
        source "${CIPI_LIB}/service.sh" 2>/dev/null || true
    fi
    local services
    if declare -f _resolve_services &>/dev/null; then
        services=$(_resolve_services all 2>/dev/null)
    else
        services="nginx mariadb valkey-server supervisor fail2ban"
    fi
    local status=ok detail="" svc
    for svc in $services; do
        if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
            status=crit
            detail="${detail}${svc} is not running\n"
        fi
    done
    if [[ "$status" == "ok" ]]; then
        _mon_result ok "all services running"
    else
        _mon_result crit "system service down" "${detail%\\n}"
    fi
}

_mon_check_workers() {
    if ! command -v supervisorctl &>/dev/null; then
        _mon_result ok "supervisor not installed"
        return 0
    fi
    shopt -s nullglob
    local confs=(/etc/supervisor/conf.d/*.conf)
    shopt -u nullglob
    local programs="" conf prog
    for conf in "${confs[@]}"; do
        for prog in $(grep '^\[program:' "$conf" 2>/dev/null | sed 's/^\[program://; s/\]$//' || true); do
            case "$prog" in
                *-worker-*|*-horizon) programs="${programs} ${prog}" ;;
            esac
        done
    done
    programs="${programs# }"
    if [[ -z "$programs" ]]; then
        _mon_result ok "no queue workers configured"
        return 0
    fi
    local status_out; status_out=$(supervisorctl status 2>/dev/null || true)
    local status=ok detail="" pline pline_one pstate
    for prog in $programs; do
        # A group with numprocs>1 lists as "prog:prog_00 …"; match both forms.
        pline=$(grep -E "^${prog}([:[:space:]])" <<<"$status_out" || true)
        if [[ -z "$pline" ]]; then
            status=crit
            detail="${detail}${prog}: no process (supervisor lost it)\n"
            continue
        fi
        while IFS= read -r pline_one; do
            pstate=$(awk '{print $2}' <<<"$pline_one")
            case "$pstate" in
                RUNNING|STARTING) ;;
                *)
                    status=crit
                    detail="${detail}${pline_one}\n"
                    ;;
            esac
        done <<< "$pline"
    done
    if [[ "$status" == "ok" ]]; then
        _mon_result ok "all workers running"
    else
        _mon_result crit "queue worker not running" "${detail%\\n}"
    fi
}

# Counts 5xx in the bytes appended to each app's nginx access log since the
# previous run (per-log byte offset in the state dir; logrotate resets it).
# The first run only establishes the baseline — never alerts on old log data.
_mon_check_http_5xx() {
    local count_lim ratio_lim
    count_lim=$(_mon_cfg_val http_5xx count 20); [[ "$count_lim" =~ ^[0-9]+$ ]] || count_lim=20
    ratio_lim=$(_mon_cfg_val http_5xx ratio 5);  [[ "$ratio_lim" =~ ^[0-9]+$ ]] || ratio_lim=5
    shopt -s nullglob
    local logs=(/home/*/logs/nginx-access.log)
    shopt -u nullglob
    if [[ ${#logs[@]} -eq 0 ]]; then
        _mon_result ok "no app access logs"
        return 0
    fi
    mkdir -p "$MONITOR_STATE_DIR" 2>/dev/null || true
    local status=ok detail="" log app off_file size prev counts total five
    local worst_five=0 worst_total=0
    for log in "${logs[@]}"; do
        app=$(basename "$(dirname "$(dirname "$log")")")
        off_file="${MONITOR_STATE_DIR}/5xx_$(md5sum <<<"$log" | cut -c1-12).off"
        size=$(stat -c %s "$log" 2>/dev/null || echo 0)
        [[ "$size" =~ ^[0-9]+$ ]] || size=0
        if [[ ! -f "$off_file" ]]; then
            echo "$size" > "$off_file" 2>/dev/null || true
            continue
        fi
        prev=$(cat "$off_file" 2>/dev/null || echo 0)
        [[ "$prev" =~ ^[0-9]+$ ]] || prev=0
        (( prev > size )) && prev=0   # rotated / truncated
        counts=$(tail -c +$(( prev + 1 )) "$log" 2>/dev/null \
            | awk '{t++} $9 ~ /^5[0-9][0-9]$/ {f++} END {print (t+0)" "(f+0)}')
        echo "$size" > "$off_file" 2>/dev/null || true
        total="${counts% *}"; five="${counts#* }"
        [[ "$total" =~ ^[0-9]+$ ]] || total=0
        [[ "$five" =~ ^[0-9]+$ ]] || five=0
        (( five > worst_five )) && { worst_five=$five; worst_total=$total; }
        if (( five >= count_lim && total > 0 && five * 100 / total >= ratio_lim )); then
            status=crit
            detail="${detail}${app}: ${five} 5xx out of ${total} requests in the last window\n"
        fi
    done
    if [[ "$status" == "ok" ]]; then
        _mon_result ok "worst app: ${worst_five} 5xx of ${worst_total} requests (limit ${count_lim} and ${ratio_lim}%)"
    else
        _mon_result crit "HTTP 5xx spike" "${detail%\\n}"
    fi
}

_mon_check_fs() {
    local detail=""
    _cipi_path_writable "${CIPI_CONFIG}" || detail="${detail}${CIPI_CONFIG} is not writable (read-only remount?)\n"
    _cipi_path_writable "${CIPI_LOG}"    || detail="${detail}${CIPI_LOG} is not writable\n"
    if [[ -z "$detail" ]]; then
        _mon_result ok "config and log filesystems writable"
    else
        _mon_result crit "filesystem read-only" "${detail%\\n}"
    fi
}

# Load needs two consecutive runs over the limit (configurable): a single
# 5-minute spike is noise, a sustained one is a problem.
_mon_check_load() {
    local factor runs_lim
    factor=$(_mon_cfg_val load factor 4); [[ "$factor" =~ ^[0-9]+$ ]] || factor=4
    runs_lim=$(_mon_cfg_val load runs 2); [[ "$runs_lim" =~ ^[0-9]+$ ]] || runs_lim=2
    local load1 ncpu
    load1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0)
    ncpu=$(nproc 2>/dev/null || echo 1)
    [[ "$ncpu" =~ ^[0-9]+$ && "$ncpu" -gt 0 ]] || ncpu=1
    local over=1
    awk -v l="$load1" -v lim="$(( factor * ncpu ))" 'BEGIN{exit !(l > lim)}' || over=0
    local consec_file="${MONITOR_STATE_DIR}/load.consec" consec=0
    if [[ "$over" == "1" ]]; then
        [[ -f "$consec_file" ]] && consec=$(cat "$consec_file" 2>/dev/null || echo 0)
        [[ "$consec" =~ ^[0-9]+$ ]] || consec=0
        consec=$(( consec + 1 ))
        echo "$consec" > "$consec_file" 2>/dev/null || true
        if (( consec >= runs_lim )); then
            _mon_result crit "load ${load1} on ${ncpu} CPU(s) for ${consec} consecutive runs (limit $(( factor * ncpu )))" \
                "Load average (1m) is ${load1} on ${ncpu} CPU(s), above ${factor}x core count for ${consec} consecutive checks."
        else
            _mon_result ok "load ${load1} elevated but below ${runs_lim} consecutive runs"
        fi
    else
        echo 0 > "$consec_file" 2>/dev/null || true
        _mon_result ok "load ${load1} on ${ncpu} CPU(s) (limit $(( factor * ncpu )))"
    fi
}

# ── Runner + alert state machine ───────────────────────────────

# _mon_apply_state <id> <status> <summary> <detail> <alert?>
# Edge-triggered: alert on ok→fail and warn↔crit transitions, one recovery
# message on fail→ok, and a reminder every reminder_minutes while failing.
_mon_apply_state() {
    local id="$1" status="$2" summary="$3" detail="$4" do_alert="${5:-false}"
    local state_file="${MONITOR_STATE_DIR}/${id}.state"
    local alert_file="${MONITOR_STATE_DIR}/${id}.lastalert"
    local since_file="${MONITOR_STATE_DIR}/${id}.since"
    local prev="ok" had_state=false
    if [[ -f "$state_file" ]]; then
        had_state=true
        prev=$(cat "$state_file" 2>/dev/null || echo ok)
    fi
    [[ "$prev" == "ok" || "$prev" == "warn" || "$prev" == "crit" ]] || prev="ok"
    echo "$status" > "$state_file" 2>/dev/null || true

    [[ "$do_alert" != "true" ]] && return 0
    declare -f cipi_notify &>/dev/null || return 0

    local label; label=$(_mon_check_label "$id")
    local host; host=$(hostname)
    local now; now=$(date +%s)

    # cipi_notify's stdout must never reach the caller: _mon_apply_state runs
    # inside the command substitution that captures _mon_run_all's JSON, and a
    # stray line from msmtp or a curl would corrupt the whole run.
    if [[ "$status" == "ok" ]]; then
        if [[ "$had_state" == "true" && "$prev" != "ok" ]]; then
            local since_line=""
            if [[ -f "$since_file" ]]; then
                local since; since=$(cat "$since_file" 2>/dev/null || echo "")
                [[ "$since" =~ ^[0-9]+$ && "$since" -gt 0 ]] \
                    && since_line="\nWas failing since: $(date -d "@${since}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo '?')"
            fi
            cipi_notify \
                "Cipi monitor recovered: ${label} on ${host}" \
                "The check is healthy again.\n\nServer: ${host}\nCheck: ${id}\nNow: ${summary}${since_line}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
                monitor_ok >/dev/null
        fi
        rm -f "$alert_file" "$since_file" 2>/dev/null || true
        return 0
    fi

    local body
    body="Server: ${host}\nCheck: ${id}\nSeverity: ${status}\n${summary}"
    [[ -n "$detail" ]] && body="${body}\n\n${detail}"
    body="${body}\n\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')\nState and thresholds: cipi monitor list"

    if [[ "$prev" == "ok" || "$prev" != "$status" ]]; then
        # Fresh failure, or warn↔crit escalation.
        [[ "$prev" == "ok" ]] && { echo "$now" > "$since_file" 2>/dev/null || true; }
        cipi_notify "Cipi monitor [${status}]: ${label} on ${host}" "$body" "monitor_${id}" >/dev/null
        echo "$now" > "$alert_file" 2>/dev/null || true
        return 0
    fi

    # Persisting failure — reminder only. `since` is when the check first went
    # bad, `last` is when we last said so; the reminder reports the former.
    local last=0 since=0
    [[ -f "$alert_file" ]] && last=$(cat "$alert_file" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    [[ -f "$since_file" ]] && since=$(cat "$since_file" 2>/dev/null || echo 0)
    [[ "$since" =~ ^[0-9]+$ && "$since" -gt 0 ]] || since=$last
    if (( now - last >= $(_mon_reminder_sec) )); then
        cipi_notify \
            "Cipi monitor reminder: ${label} still ${status} on ${host}" \
            "${body}\nFailing since: $(date -d "@${since}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo '?')" \
            "monitor_${id}" >/dev/null
        echo "$now" > "$alert_file" 2>/dev/null || true
    fi
    return 0
}

# _mon_run_all [alert?] — run every enabled check, print a JSON array.
_mon_run_all() {
    local do_alert="${1:-false}"
    _mon_ensure_config
    mkdir -p "$MONITOR_STATE_DIR" 2>/dev/null || true
    local results="[]"
    local id label out status summary detail
    while IFS='|' read -r id label; do
        [[ -z "$id" ]] && continue
        if ! _mon_check_enabled "$id"; then
            results=$(jq -c --arg id "$id" '. + [{check:$id, status:"disabled", summary:"", detail:""}]' <<<"$results")
            continue
        fi
        out=$("_mon_check_${id}" 2>/dev/null) \
            || out=$(_mon_result crit "check '${id}' itself failed to run" "")
        [[ -n "$out" ]] || out=$(_mon_result crit "check '${id}' produced no output" "")
        status=$(jq -r '.status // "crit"' <<<"$out" 2>/dev/null) || status=crit
        summary=$(jq -r '.summary // ""' <<<"$out" 2>/dev/null)
        detail=$(jq -r '.detail // ""' <<<"$out" 2>/dev/null)
        _mon_apply_state "$id" "$status" "$summary" "$detail" "$do_alert"
        results=$(jq -c --arg id "$id" --arg s "$status" --arg m "$summary" --arg d "$detail" \
            '. + [{check:$id, status:$s, summary:$m, detail:$d}]' <<<"$results")
    done < <(_mon_catalog)
    echo "$results"
}

# ── Cron / helper installation ─────────────────────────────────

_mon_ensure_cron() {
    mkdir -p "$MONITOR_STATE_DIR" 2>/dev/null || true
    if [[ ! -x "$MONITOR_HELPER" && -f "${CIPI_LIB}/cipi-monitor.sh" ]]; then
        if cp "${CIPI_LIB}/cipi-monitor.sh" "$MONITOR_HELPER" 2>/dev/null; then
            chmod 755 "$MONITOR_HELPER" 2>/dev/null || true
        else
            warn "Could not install ${MONITOR_HELPER} — the 5-minute checks will not run"
        fi
    fi
    if [[ ! -f "$MONITOR_CRON" ]]; then
        if cat > "$MONITOR_CRON" 2>/dev/null <<EOF
# Cipi system monitor (every 5 minutes)
*/5 * * * * root ${MONITOR_HELPER} >/dev/null 2>&1
EOF
        then
            chmod 644 "$MONITOR_CRON" 2>/dev/null || true
        else
            warn "Could not write ${MONITOR_CRON} — the 5-minute checks will not run"
        fi
    fi
}

# ── CLI ────────────────────────────────────────────────────────

_mon_status_icon() {
    case "$1" in
        ok)       printf "${GREEN}●${NC}" ;;
        warn)     printf "${YELLOW}●${NC}" ;;
        crit)     printf "${RED}●${NC}" ;;
        disabled) printf "${DIM}○${NC}" ;;
        *)        printf "${DIM}?${NC}" ;;
    esac
}

_mon_run_cmd() {
    parse_args "$@"
    # warn() writes to stdout; --json must stay machine-readable, so the
    # "could not install the cron" diagnostics go to stderr.
    _mon_ensure_cron >&2
    local results; results=$(_mon_run_all true)
    if [[ "${ARG_json:-}" == "true" ]]; then
        jq -n --argjson checks "$results" '{checks: $checks}'
    else
        echo -e "\n${BOLD}System monitor${NC} ${DIM}— $(hostname), $(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        local row id status summary
        while IFS= read -r row; do
            [[ -z "$row" ]] && continue
            id=$(jq -r '.check' <<<"$row")
            status=$(jq -r '.status' <<<"$row")
            summary=$(jq -r '.summary' <<<"$row")
            printf "  %b %-10s %s\n" "$(_mon_status_icon "$status")" "$id" "${DIM}${summary}${NC}"
        done < <(jq -c '.[]' <<<"$results")
        echo ""
    fi
    # Exit 1 when anything is warn/crit — scriptable.
    jq -e '[.[] | select(.status == "warn" or .status == "crit")] | length == 0' <<<"$results" >/dev/null
}

_mon_list() {
    parse_args "$@"
    _mon_ensure_config
    local cfg; cfg=$(_mon_cfg)
    if [[ "${ARG_json:-}" == "true" ]]; then
        local items="[]" id
        for id in $(_mon_catalog | cut -d'|' -f1); do
            local st="" la=0
            [[ -f "${MONITOR_STATE_DIR}/${id}.state" ]] && st=$(cat "${MONITOR_STATE_DIR}/${id}.state" 2>/dev/null)
            [[ -f "${MONITOR_STATE_DIR}/${id}.lastalert" ]] && la=$(cat "${MONITOR_STATE_DIR}/${id}.lastalert" 2>/dev/null)
            [[ "$la" =~ ^[0-9]+$ ]] || la=0
            items=$(jq -c --arg id "$id" --arg st "$st" --argjson la "$la" \
                --argjson cfg "$(jq -c --arg id "$id" '.checks[$id] // {}' <<<"$cfg")" \
                '. + [{check:$id, config:$cfg, state:(if $st=="" then null else $st end), last_alert:(if $la==0 then null else $la end)}]' \
                <<<"$items")
        done
        jq -n --argjson checks "$items" \
            --argjson reminder "$(jq '.reminder_minutes // 240' <<<"$cfg")" \
            '{reminder_minutes: $reminder, checks: $checks}'
        return 0
    fi

    echo -e "\n${BOLD}Monitor checks${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${DIM}  Run by cron every 5 minutes; alerts on state change, recovery, and a reminder every $(_mon_cfg | jq -r '.reminder_minutes // 240') min while failing.${NC}\n"
    local id label enabled st la
    while IFS='|' read -r id label; do
        [[ -z "$id" ]] && continue
        enabled=$(jq -r --arg id "$id" '.checks[$id].enabled != false' <<<"$cfg")
        st="never run"
        [[ -f "${MONITOR_STATE_DIR}/${id}.state" ]] && st=$(cat "${MONITOR_STATE_DIR}/${id}.state" 2>/dev/null)
        la=""
        if [[ -f "${MONITOR_STATE_DIR}/${id}.lastalert" ]]; then
            la=$(cat "${MONITOR_STATE_DIR}/${id}.lastalert" 2>/dev/null)
            [[ "$la" =~ ^[0-9]+$ && "$la" -gt 0 ]] && la="last alert $(date -d "@${la}" '+%Y-%m-%d %H:%M' 2>/dev/null)" || la=""
        fi
        if [[ "$enabled" == "true" ]]; then
            printf "  ${GREEN}●${NC} %-10s %-28s ${DIM}state: %-10s %s${NC}\n" "$id" "$label" "$st" "$la"
        else
            printf "  ${DIM}○ %-10s %-28s disabled${NC}\n" "$id" "$label"
        fi
        local keys key val opts=""
        keys=$(_mon_settable_keys "$id")
        for key in $keys; do
            val=$(jq -r --arg id "$id" --arg k "$key" '.checks[$id][$k] // empty' <<<"$cfg")
            [[ -n "$val" ]] && opts="${opts} ${key}=${val}"
        done
        [[ -n "$opts" ]] && echo -e "    ${DIM}thresholds:${opts}${NC}"
    done < <(_mon_catalog)
    echo ""
    echo -e "  ${DIM}Toggle: cipi monitor enable|disable <check>   Thresholds: cipi monitor set <check> --key=value${NC}"
    echo ""
}

_mon_set_enabled() {
    local id="$1" enabled="$2"
    _mon_known_check "$id" || { error "Unknown check: ${id}"; exit 1; }
    _mon_ensure_config
    _mon_cfg | jq --arg c "$id" --argjson e "$enabled" '.checks[$c].enabled = $e' | vault_write monitor.json
    if [[ "$enabled" == "true" ]]; then
        _mon_ensure_cron
        success "Enabled: ${id} ($(_mon_check_label "$id"))"
    else
        success "Disabled: ${id} ($(_mon_check_label "$id"))"
    fi
}

_mon_set() {
    local id="${1:-}"; shift || true
    parse_args "$@"
    if [[ "$id" == "reminder" ]]; then
        local minutes="${ARG_minutes:-}"
        [[ "$minutes" =~ ^[0-9]+$ && "$minutes" -ge 15 ]] \
            || { error "Usage: cipi monitor set reminder --minutes=240 (at least 15)"; exit 1; }
        _mon_ensure_config
        _mon_cfg | jq --argjson m "$minutes" '.reminder_minutes = $m' | vault_write monitor.json
        success "Reminder interval set to ${minutes} minutes"
        return 0
    fi
    _mon_known_check "$id" || { error "Unknown check: ${id:-<missing>}"; exit 1; }
    local keys; keys=$(_mon_settable_keys "$id")
    [[ -z "$keys" ]] && { error "Check '${id}' has no thresholds to set"; exit 1; }
    local changed=false key val
    for key in $keys; do
        local varname="ARG_${key}"
        val="${!varname:-}"
        [[ -z "$val" ]] && continue
        [[ "$val" =~ ^[0-9]+$ ]] || { error "--${key} must be a whole number"; exit 1; }
        _mon_ensure_config
        _mon_cfg | jq --arg c "$id" --arg k "$key" --argjson v "$val" '.checks[$c][$k] = $v' | vault_write monitor.json
        changed=true
        success "${id}: ${key} = ${val}"
    done
    [[ "$changed" == "false" ]] && { error "Nothing to set. Keys for '${id}': ${keys}"; exit 1; }
    if [[ "$id" == "disk" ]]; then
        local w c
        w=$(_mon_cfg_val disk warn 80); c=$(_mon_cfg_val disk crit 90)
        (( w >= c )) && warn "warn (${w}%) is not below crit (${c}%) — alerts escalate warn→crit, keep warn < crit"
    fi
}

_mon_test() {
    step "Sending a test alert through every configured channel (and email)..."
    cipi_notify \
        "Cipi monitor test on $(hostname)" \
        "This is how a monitor alert looks.\n\nServer: $(hostname)\nCheck: test\nSeverity: warn\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        ""
    success "Test sent — email needs 'cipi smtp configure', chat needs 'cipi notifications channel add …'"
}

monitor_command() {
    local sub="${1:-run}"
    # `cipi monitor --json` is the documented form: a leading flag means
    # "run now", so keep it in "$@" instead of treating it as a subcommand.
    if [[ "$sub" == --* ]]; then
        sub="run"
    else
        shift || true
    fi
    case "$sub" in
        run|check|"") _mon_run_cmd "$@" ;;
        list|ls)      _mon_list "$@" ;;
        enable)       [[ -n "${1:-}" ]] && _mon_set_enabled "$1" true  || { error "Usage: cipi monitor enable <check>"; exit 1; } ;;
        disable)      [[ -n "${1:-}" ]] && _mon_set_enabled "$1" false || { error "Usage: cipi monitor disable <check>"; exit 1; } ;;
        set)          _mon_set "$@" ;;
        test)         _mon_test ;;
        *)
            error "Use: run list enable disable set test"
            echo -e "  ${DIM}cipi monitor [--json] | set disk --warn=80 --crit=90 | set reminder --minutes=240${NC}"
            exit 1
            ;;
    esac
}
