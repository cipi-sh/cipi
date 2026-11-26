#!/bin/bash
#############################################
# Cipi — Notifications (cipi notification)
#
# Where they go — channels: SMTP (smtp.json, lib/smtp.sh, unchanged since
# before 5.10.0 and shown here as the channel "smtp"), and the channels of
# lib/alerts.sh (Resend, Amazon SES, Slack, Discord, Mattermost, Google
# Chat, Telegram, ntfy, Pushover, webhook).
# What sends them — triggers: this file. An enabled trigger reaches every
# enabled channel that takes it: a channel takes every trigger, or only the
# events it was given (cipi notification events <channel> …) — categories
# (security, deploy, backup…), single triggers, or "urgent" (failures and
# security events). One channel for everything, one for the alarms, one for
# deploys.
#
# `cipi notifications` (the older name) and `cipi smtp` keep working.
#############################################

[[ -z "${NOTIFICATIONS_CFG:-}" ]] && readonly NOTIFICATIONS_CFG="${CIPI_CONFIG}/notifications.json"

# id|category|label — one per line
_notify_trigger_catalog() {
    cat <<'EOF'
app_create|Apps|App created
app_edit|Apps|App modified
app_delete|Apps|App deleted
app_suspend|Apps|App suspended
app_unsuspend|Apps|App unsuspended
app_ssh_password_reset|Apps|App SSH password reset
app_ssh_access|Apps|App user SSH access enabled or disabled
app_db_password_reset|Apps|App DB password reset
alias_add|Domains|Alias added
alias_remove|Domains|Alias removed
www_add|Domains|WWW alias added
www_force_to_root|Domains|WWW force to-root
www_force_from_root|Domains|WWW force from-root
www_clear|Domains|WWW redirect cleared
redirect_change|Domains|Redirect set, toggled, added or removed
proxy_change|Domains|Proxy route added or removed
auth_create|Auth|Composer auth.json created
auth_edit|Auth|Composer auth.json edited
auth_delete|Auth|Composer auth.json deleted
basicauth_enable|Basic auth|HTTP basic auth enabled
basicauth_disable|Basic auth|HTTP basic auth disabled
deploy_success|Deploy|Deploy succeeded
deploy_fail|Deploy|Deploy failed
deploy_rollback|Deploy|Deploy rollback
deploy_snapshot_fail|Deploy|Pre-deploy DB snapshot failed
health_fail|Health|HTTP healthcheck failed (periodic, after 3 failures)
deploy_health_fail|Health|Post-deploy healthcheck failed
monitor_disk|Monitor|Disk usage over threshold
monitor_app_disk|Monitor|App near or over its disk limit
monitor_ssl|Monitor|SSL certificate expiring
monitor_services|Monitor|System service not running
monitor_workers|Monitor|Queue worker / Horizon not running
monitor_http_5xx|Monitor|HTTP 5xx spike in access logs
monitor_fs|Monitor|Filesystem read-only / config not writable
monitor_load|Monitor|Load average over threshold
monitor_tunnel|Monitor|Cloudflare Tunnel down or degraded
monitor_ok|Monitor|Monitor check recovered
ssl_install|SSL|SSL certificate installed
ssl_force|SSL|HTTP → HTTPS redirect forced
ssl_renew|SSL|SSL certificates renewed
php_install|PHP|PHP version installed
php_switch|PHP|System PHP switched
php_remove|PHP|PHP version removed
php_upgrade|PHP|PHP packages upgraded
frankenphp_upgrade|PHP|FrankenPHP build of an Octane app changed or upgraded
frankenphp_available|Updates|FrankenPHP release on another PHP minor or major, not applied
app_jit|PHP|JIT turned on or off for an app
nginx_upgrade|Services|Nginx packages upgraded
mariadb_upgrade|Database|MariaDB / MySQL packages upgraded
pgsql_upgrade|Database|PostgreSQL packages upgraded
valkey_upgrade|Services|Valkey packages upgraded
node_upgrade|Node|Node.js runtimes upgraded (automatic update)
composer_upgrade|Updates|Composer upgraded (automatic update)
pending_report|Updates|A reboot, a patch or a warning is waiting (daily check)
reboot|Updates|Server reboot requested or automatic
valkey_isolate|Services|App moved to its own Valkey instance, or back
package_install|Packages|Optional package installed
package_remove|Packages|Optional package removed
db_create|Database|Database created
db_delete|Database|Database deleted
db_switch|Database|Server on port 3306 replaced (MariaDB ⇄ MySQL)
search_install|Search|Meilisearch installed
search_enable|Search|Search enabled for an app
node_default|Node|Server-wide Node version changed
search_disable|Search|Search disabled for an app
search_key_rotate|Search|Meilisearch API key rotated
search_upgrade|Search|Meilisearch upgraded
search_remove|Search|Meilisearch removed
worker_add|Workers|Worker added
worker_remove|Workers|Worker removed
ssh_key_add|SSH keys|SSH key added
ssh_key_rename|SSH keys|SSH key renamed
ssh_key_remove|SSH keys|SSH key removed
ssh_login|Security|SSH login (cipi/root/sudo users)
sudo|Security|Sudo elevation
su|Security|su to root by cipi
credentials_show|Security|Server credentials shown or exported (cipi credentials)
gui_sso|Security|GUI single sign-on configured or disabled
crowdsec_enable|Security|CrowdSec enabled
crowdsec_disable|Security|CrowdSec disabled
crowdsec_rescue|Security|CrowdSec rescue token used or rotated
zt_enable|Security|Cloudflare Zero Trust enabled
zt_disable|Security|Cloudflare Zero Trust disabled
zt_lock_http|Security|HTTP ports locked (Cloudflare)
zt_lock_ssh|Security|SSH port closed (Cloudflare Tunnel)
scan_enable|Security|Nightly malware scan enabled
scan_hit|Security|Malware scan found infected files
scan_incomplete|Security|Malware scan did not finish
scan_integrity|Security|Release files drifted from the deploy manifest
backup_fail|Backup|Backup failed
backup_stale|Backup|Backup overdue (no successful run in its window)
cron_fail|Cron|Cron job failed
ini_set|PHP|PHP setting changed
yml_apply|cipi.yml|cipi.yml applied
yml_fail|cipi.yml|cipi.yml invalid or could not be applied
yml_post_fail|cipi.yml|Post-deploy step failed
self_update|Updates|Cipi updated itself
reset_root_password|Reset|Root SSH password reset
reset_db_password|Reset|MariaDB / MySQL root password reset
reset_valkey_password|Reset|Valkey password reset
api_configure|API|Panel API configured
api_update|API|Panel API updated
api_upgrade|API|Panel API upgraded
api_ssl|API|Panel API SSL installed
git_configure|Git|Git provider token configured
sync_export|Sync|Apps exported
sync_import|Sync|Apps imported
sync_push|Sync|Apps pushed to remote
service_restart|Services|Service restarted
service_start|Services|Service started
service_stop|Services|Service stopped
EOF
}

# ── Which channel takes which events ─────────────────────────
#
# A channel's `events` (alerts.json channels[].events, smtp.json .events):
# absent, null, [] or ["all"] — every trigger; otherwise a list of selectors,
# any of which lets a trigger through:
#   <category>   a category of the catalog, as an id: security, deploy,
#                backup, monitor, basic-auth, ssh-keys, cipi-yml…
#   <trigger>    one trigger: backup_fail, deploy_success…
#   urgent       failures and security events — the triggers ntfy and
#                Pushover already raise in priority (_notify_trigger_urgent)
# A notification without a trigger (cipi monitor test) reaches every channel.
# The triggers on and off (cipi notification triggers) still come first: a
# trigger that is off reaches no channel.

# "Basic auth" → basic-auth, "cipi.yml" → cipi-yml.
_notify_slug() {
    printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

_notify_trigger_category_id() {   # <trigger> → its category, as an id
    _notify_slug "$(_notify_trigger_catalog | awk -F'|' -v t="${1:-}" '$1 == t { print $2; exit }')"
}

# Failures and security events: what needs someone now. ntfy and Pushover
# raise these in priority; "urgent" sends a channel these alone.
_notify_trigger_urgent() {
    local urgent=" ssh_login sudo su scan_hit scan_integrity scan_incomplete crowdsec_rescue"
    urgent+=" backup_fail backup_stale deploy_fail deploy_health_fail deploy_snapshot_fail health_fail"
    urgent+=" monitor_services monitor_workers monitor_fs monitor_disk monitor_app_disk monitor_http_5xx monitor_tunnel"
    urgent+=" cron_fail yml_fail yml_post_fail "
    [[ -n "${1:-}" && "$urgent" == *" ${1} "* ]]
}

# Every category, in catalog order: id|label|number of triggers
_notify_categories() {
    local cat id
    _notify_trigger_catalog | awk -F'|' '!seen[$2]++ { order[++n] = $2 } { count[$2]++ }
        END { for (i = 1; i <= n; i++) print order[i] "|" count[order[i]] }' \
    | while IFS='|' read -r cat id; do
        printf '%s|%s|%s\n' "$(_notify_slug "$cat")" "$cat" "$id"
    done
}

_notify_categories_json() {
    _notify_categories | jq -R -s -c '[split("\n")[] | select(length > 0) | split("|")
        | {id: .[0], label: .[1], triggers: (.[2] | tonumber)}]'
}

# "security,deploy,backup_fail" → ["security","deploy","backup_fail"], or
# null for every trigger ("all", or nothing). Every selector is checked; the
# first one that is none of a category, a trigger, urgent or all is printed on
# stderr and the function fails.
_notify_events_parse() {   # <comma-separated selectors>
    local raw="${1:-}" sel cats out='[]'
    raw="${raw// /}"
    [[ -z "$raw" || "$raw" == all ]] && { echo null; return 0; }
    cats=" $(_notify_categories | cut -d'|' -f1 | tr '\n' ' ') "
    IFS=',' read -r -a _sels <<< "$raw"
    for sel in "${_sels[@]}"; do
        [[ -z "$sel" ]] && continue
        sel=$(printf '%s' "$sel" | tr '[:upper:]' '[:lower:]')
        if [[ "$sel" == all ]]; then echo null; return 0; fi
        if [[ "$sel" == urgent || "$cats" == *" ${sel} "* ]] || _notify_trigger_known "$sel"; then
            out=$(jq -c --arg s "$sel" 'if index($s) then . else . + [$s] end' <<< "$out")
        else
            printf '%s' "$sel" >&2
            return 1
        fi
    done
    [[ "$out" == "[]" ]] && { echo null; return 0; }
    echo "$out"
}

# 0 when a channel with these events takes this trigger.
_notify_events_take() {   # <events JSON: array|null> <trigger>
    local ev="${1:-null}" t="${2:-}" cat urgent=false
    [[ -z "$t" ]] && return 0
    [[ -z "$ev" || "$ev" == null || "$ev" == "[]" ]] && return 0
    jq -e 'type == "array" and (index("all") | not)' <<< "$ev" >/dev/null 2>&1 || return 0
    cat=$(_notify_trigger_category_id "$t")
    _notify_trigger_urgent "$t" && urgent=true
    jq -e --arg t "$t" --arg c "$cat" --argjson u "$urgent" \
        'any(.[]; . == $t or ($c != "" and . == $c) or ($u and . == "urgent"))' <<< "$ev" >/dev/null 2>&1
}

# What a channel takes, for people: "everything", or the selectors with labels.
_notify_events_label() {   # <events JSON>
    local ev="${1:-null}"
    if [[ -z "$ev" || "$ev" == null || "$ev" == "[]" ]] || jq -e 'type != "array" or index("all")' <<< "$ev" >/dev/null 2>&1; then
        echo "everything"; return 0
    fi
    jq -r 'join(", ")' <<< "$ev"
}

_notify_smtp_events() {
    [[ -f "${SMTP_CFG:-/nonexistent}" ]] || { echo null; return 0; }
    vault_read smtp.json 2>/dev/null | jq -c '.events // null' 2>/dev/null || echo null
}

# Everything a notification goes to: SMTP and the channels of alerts.json,
# each only for the events it takes. Best-effort: a channel that fails never
# stops the others, nor the command that raised the notification. The PAM,
# cron and deploy-webhook helpers send through here too — before 5.15.0 they
# reached SMTP alone.
_notify_fanout() {   # <subject> <body> [trigger]
    local subject="$1" body="$2" trigger="${3:-}"
    declare -f log_event >/dev/null 2>&1 || log_event() { :; }
    declare -f _alerts_deliver >/dev/null 2>&1 || source "${CIPI_LIB}/alerts.sh" 2>/dev/null || true
    if declare -f _smtp_send >/dev/null 2>&1 && _notify_events_take "$(_notify_smtp_events)" "$trigger"; then
        _smtp_send "$subject" "$body" 2>/dev/null || true
    fi
    if declare -f _alerts_deliver >/dev/null 2>&1; then
        _alerts_deliver "$subject" "$body" "$trigger" || true
    fi
    return 0
}

# cipi notification events [<channel> [<selectors>|all]] [--json]
_notify_events_command() {
    declare -f _alerts_list >/dev/null 2>&1 || source "${CIPI_LIB}/alerts.sh"
    local id="" sel="" json=false a
    for a in "$@"; do
        case "$a" in
            --json) json=true ;;
            --events=*) sel="${a#--events=}" ;;
            --*) error "Unknown option: ${a}"; exit 1 ;;
            *) if [[ -z "$id" ]]; then id="$a"; elif [[ -z "$sel" ]]; then sel="$a"; fi ;;
        esac
    done
    if [[ -z "$id" ]]; then
        _notify_events_list "$json"
        return 0
    fi
    _notify_is_channel "$id" || { error "Channel '${id}' not found (cipi notification)"; exit 1; }
    if [[ -z "$sel" ]]; then
        local ev
        ev=$(_notify_channel_events "$id")
        if [[ "$json" == true ]]; then
            jq -n --arg id "$id" --argjson e "$ev" '{id: $id, events: $e}'
        else
            echo -e "  ${BOLD}${id}${NC} takes: $(_notify_events_label "$ev")"
        fi
        return 0
    fi
    _notify_set_events "$id" "$sel"
    if [[ "$json" == true ]]; then
        jq -n --arg id "$id" --argjson e "$(_notify_channel_events "$id")" '{id: $id, events: $e}'
    fi
}

_notify_channel_events() {   # <id> → JSON array|null
    if [[ "$1" == smtp ]]; then
        _notify_smtp_events
    else
        vault_read alerts.json 2>/dev/null | jq -c --arg id "$1" '(.channels[]? | select(.id == $id) | .events) // null' 2>/dev/null | head -1
    fi
}

# The selectors as JSON (array|null) on stdout, or the command stops on the
# first one that is not a category, a trigger, urgent or all. Not in a
# subshell when the refusal must stop the command: call it bare, or check $?.
_notify_events_checked() {   # <selectors|all>
    local ev bad
    if ev=$(_notify_events_parse "${1:-}" 2>/dev/null); then
        printf '%s\n' "$ev"
        return 0
    fi
    bad=$(_notify_events_parse "${1:-}" 2>&1 >/dev/null || true)
    error "Not a category, a trigger, urgent or all: '${bad}'"
    echo "  Categories: urgent $(_notify_categories | cut -d'|' -f1 | tr '\n' ' ')" >&2
    echo "  Triggers:   cipi notification triggers" >&2
    exit 1
}

# Sets what a channel takes. The channel must exist; every selector is
# checked before anything is written.
_notify_set_events() {   # <id> <selectors|all>
    local id="$1" sel="$2" ev
    _notify_is_channel "$id" || { error "Channel '${id}' not found"; exit 1; }
    _notify_events_checked "$sel" >/dev/null
    ev=$(_notify_events_parse "$sel")
    if [[ "$id" == smtp ]]; then
        [[ -f "$SMTP_CFG" ]] || { error "SMTP is not configured"; exit 1; }
        vault_read smtp.json | jq --argjson e "$ev" 'if $e == null then del(.events) else .events = $e end' | vault_write smtp.json
    else
        _alerts_ensure_config
        vault_read alerts.json | jq --arg id "$id" --argjson e "$ev" \
            '.channels |= map(if .id == $id then (if $e == null then del(.events) else .events = $e end) else . end)' \
            | vault_write alerts.json
    fi
    log_action "NOTIFICATION EVENTS: ${id} → $(_notify_events_label "$ev")"
    success "Channel '${id}' takes: $(_notify_events_label "$ev")"
}

_notify_events_list() {   # <json true|false>
    local rows='[]' ch
    if [[ -f "${SMTP_CFG:-/nonexistent}" ]]; then
        rows=$(jq -c --argjson e "$(_notify_smtp_events)" '. + [{id: "smtp", type: "smtp", events: $e}]' <<< "$rows")
    fi
    if [[ -f "${ALERTS_CFG:-/nonexistent}" ]]; then
        ch=$(vault_read alerts.json 2>/dev/null | jq -c '[.channels[]? | {id, type, events: (.events // null)}]' 2>/dev/null) || ch='[]'
        rows=$(jq -c --argjson c "${ch:-[]}" '. + $c' <<< "$rows")
    fi
    if [[ "$1" == true ]]; then
        jq -n --argjson r "$rows" --argjson c "$(_notify_categories_json)" \
            '{channels: $r, categories: $c, selectors: (["all", "urgent"] + [$c[].id])}'
        return 0
    fi
    echo -e "\n${BOLD}What each channel takes${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ "$(jq 'length' <<< "$rows")" == 0 ]]; then
        echo -e "  ${DIM}No channels yet — cipi notification add <type> <id> …${NC}\n"
        return 0
    fi
    local id type ev
    while IFS=$'\t' read -r id type ev; do
        printf "  %-16s %-12s %s\n" "$id" "$type" "$(_notify_events_label "$ev")"
    done < <(jq -r '.[] | [.id, .type, (.events | tojson)] | @tsv' <<< "$rows")
    echo ""
    echo -e "  ${DIM}Change: cipi notification events <channel> security,deploy | urgent | backup_fail,… | all${NC}"
    echo -e "  ${DIM}Categories: $(_notify_categories | cut -d'|' -f1 | tr '\n' ' ')${NC}"
    echo ""
}

_notify_default_triggers_json() {
    _notify_trigger_catalog | cut -d'|' -f1 | jq -R -s '
        split("\n") | map(select(length > 0)) | reduce .[] as $t ({}; .[$t] = true)
    '
}

_notify_ensure_config() {
    if [[ ! -f "$NOTIFICATIONS_CFG" ]]; then
        _notify_default_triggers_json | jq '{triggers: .}' | vault_write notifications.json
    fi
}

_notify_trigger_known() {
    local trigger="$1"
    _notify_trigger_catalog | cut -d'|' -f1 | grep -qx "$trigger"
}

_notify_trigger_label() {
    local trigger="$1"
    _notify_trigger_catalog | awk -F'|' -v t="$trigger" '$1 == t { print $3; exit }'
}

_notify_trigger_enabled() {
    local trigger="${1:-}"
    [[ -z "$trigger" ]] && return 0
    if [[ ! -f "$NOTIFICATIONS_CFG" ]]; then
        return 0
    fi
    local val
    # NB: jq's `// true` treats false as empty, so a disabled trigger would
    # read as enabled — `!= false` is the correct "default true".
    val=$(vault_read notifications.json 2>/dev/null | jq -r --arg t "$trigger" '.triggers[$t] != false' 2>/dev/null) || val="true"
    [[ "$val" == "true" ]]
}

_notify_set_trigger() {
    local trigger="$1" enabled="$2"
    _notify_trigger_known "$trigger" || { error "Unknown trigger: ${trigger}"; exit 1; }
    _notify_ensure_config
    vault_read notifications.json | \
        jq --arg t "$trigger" --argjson e "$([[ "$enabled" == "true" ]] && echo true || echo false)" \
        '.triggers[$t] = $e' | vault_write notifications.json
}

_notify_list() {
    _notify_ensure_config
    local cfg; cfg=$(vault_read notifications.json)
    local smtp_hint=""
    if declare -f _smtp_is_enabled &>/dev/null && ! _smtp_is_enabled 2>/dev/null; then
        smtp_hint="${DIM}  (SMTP not configured — cipi notification add smtp …, or another channel)${NC}"
    fi

    echo -e "\n${BOLD}Notification triggers${NC}${smtp_hint}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${DIM}  A trigger that is on reaches every enabled channel that takes it: SMTP, Resend, SES, Slack,${NC}"
    echo -e "${DIM}  Discord, Mattermost, Google Chat, Telegram, ntfy, Pushover, webhook (cipi notification events).${NC}"
    echo -e "${DIM}  Events are always logged to /var/log/cipi/events.log.${NC}\n"

    local cur_cat="" line id cat label on
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        id="${line%%|*}"; line="${line#*|}"
        cat="${line%%|*}"; label="${line#*|}"
        on=$(echo "$cfg" | jq -r --arg t "$id" '.triggers[$t] != false')
        if [[ "$cat" != "$cur_cat" ]]; then
            cur_cat="$cat"
            echo -e "  ${BOLD}${cat}${NC}"
        fi
        if [[ "$on" == "true" ]]; then
            printf "    ${GREEN}●${NC} %-22s ${DIM}%s${NC}\n" "$id" "$label"
        else
            printf "    ${DIM}○${NC} %-22s ${DIM}%s${NC}\n" "$id" "$label"
        fi
    done < <(_notify_trigger_catalog)
    echo ""
    echo -e "  ${DIM}Toggle: cipi notification triggers enable|disable <trigger>${NC}"
    echo ""
}

_notify_enable_all() {
    _notify_ensure_config
    _notify_default_triggers_json | jq '{triggers: .}' | vault_write notifications.json
    success "All notification triggers enabled"
}

_notify_disable_all() {
    _notify_ensure_config
    _notify_default_triggers_json | jq 'map_values(false) | {triggers: .}' | vault_write notifications.json
    success "All notification triggers disabled"
}

_notify_reset() {
    _notify_enable_all
    info "Triggers reset to defaults (all enabled)"
}

_notify_is_channel() {   # <id>: smtp, or an id in alerts.json
    [[ "${1:-}" == smtp ]] && return 0
    [[ -f "${ALERTS_CFG:-/nonexistent}" ]] || return 1
    vault_read alerts.json 2>/dev/null | jq -e --arg id "$1" '.channels[]? | select(.id == $id)' >/dev/null 2>&1
}

# The SMTP channel, as a row of the channel list.
_notify_smtp_row() {
    if [[ ! -f "$SMTP_CFG" ]]; then
        return 1
    fi
    local _sj; _sj=$(vault_read smtp.json)
    jq -c '{id: "smtp", type: "smtp", enabled: (.enabled // false), from: (.from // null),
            to: ((.to // "") | split(",") | map(gsub(" "; "")) | map(select(. != ""))),
            host: (.host // null), port: ((.port // "587") | tostring), tls: (.tls != false),
            events: (.events // null)}' <<< "$_sj"
}

# cipi notification [status] [--json]: every channel, SMTP included, and the triggers.
_notify_status() {
    parse_args "$@"
    declare -f _alerts_list >/dev/null 2>&1 || source "${CIPI_LIB}/alerts.sh"
    declare -f _smtp_status >/dev/null 2>&1 || source "${CIPI_LIB}/smtp.sh"
    _notify_ensure_config
    local on total
    total=$(_notify_trigger_catalog | grep -c '|' || true)
    on=$(vault_read notifications.json | jq --argjson d "$(_notify_default_triggers_json)" '[($d + .triggers) | to_entries[] | select(.value != false)] | length')
    if [[ "${ARG_json:-}" == true ]]; then
        local smtp chans
        smtp=$(_notify_smtp_row || echo null)
        chans=$(_alerts_list --json | jq -c '.channels')
        jq -n --argjson s "$smtp" --argjson c "$chans" --argjson on "$on" --argjson t "$total" \
            --arg types "smtp $(_alert_types)" --argjson cats "$(_notify_categories_json)" \
            '{channels: ((if $s == null then [] else [$s] end) + ($c | map(.events = (.events // null)))),
              triggers: {enabled: $on, total: $t},
              types: ($types | split(" ")),
              categories: $cats, selectors: (["all", "urgent"] + [$cats[].id])}'
        return 0
    fi
    echo -e "\n${BOLD}Notifications${NC} ${DIM}— an enabled trigger reaches every enabled channel that takes it${NC}"
    echo -e "\n${BOLD}SMTP${NC}"
    if [[ -f "$SMTP_CFG" ]]; then
        local _sj; _sj=$(vault_read smtp.json)
        local st="${YELLOW}disabled${NC}"; [[ "$(jq -r '.enabled // false' <<< "$_sj")" == true ]] && st="${GREEN}enabled${NC}"
        echo -e "  ${st}  $(jq -r '.host' <<< "$_sj"):$(jq -r '.port // 587' <<< "$_sj")  $(jq -r '.from // ""' <<< "$_sj") → $(jq -r '.to // ""' <<< "$_sj")  ${DIM}takes $(_notify_events_label "$(jq -c '.events // null' <<< "$_sj")")${NC}"
    else
        echo -e "  ${DIM}not configured — cipi notification add smtp --host= --user= --password= --from= --to=${NC}"
    fi
    _alerts_list
    echo -e "${BOLD}Triggers${NC}  ${on}/${total} on  ${DIM}— cipi notification triggers${NC}\n"
}

# Which one an `enable|disable <name>` means: a trigger (the older form) or a channel.
_notify_toggle() {   # <on|off> <name>
    local to="$1" name="${2:-}" is_t=false is_c=false
    [[ -z "$name" ]] && { error "Usage: cipi notification enable|disable <channel id|trigger>"; exit 1; }
    _notify_trigger_known "$name" && is_t=true
    _notify_is_channel "$name" && is_c=true
    if [[ "$is_t" == true && "$is_c" == true ]]; then
        error "'${name}' is a trigger and a channel: cipi notification triggers ${to/on/enable} ${name}, or rename the channel"
        exit 1
    fi
    if [[ "$is_c" == true ]]; then
        if [[ "$name" == smtp ]]; then
            [[ "$to" == on ]] && _smtp_enable || _smtp_disable
        else
            _alerts_set_enabled "$name" "$( [[ "$to" == on ]] && echo true || echo false)"
        fi
        return 0
    fi
    if [[ "$is_t" == true ]]; then
        _notify_set_trigger "$name" "$( [[ "$to" == on ]] && echo true || echo false)"
        success "$( [[ "$to" == on ]] && echo Enabled || echo Disabled ): ${name} ($(_notify_trigger_label "$name"))"
        return 0
    fi
    error "No channel or trigger '${name}' (cipi notification · cipi notification triggers)"
    exit 1
}

# cipi notification triggers --json: every trigger with its category, label
# and state, in catalog order.
_notify_triggers_json() {
    _notify_ensure_config
    local cfg; cfg=$(vault_read notifications.json)
    _notify_trigger_catalog | jq -R -s --argjson cfg "$cfg" '
        [split("\n")[] | select(length > 0) | split("|")
         | {id: .[0], category: .[1],
            category_id: (.[1] | ascii_downcase | gsub("[^a-z0-9]+"; "-") | gsub("^-+|-+$"; "")),
            label: (.[2:] | join("|")),
            enabled: ($cfg.triggers[.[0]] != false)}]
        | {triggers: ., enabled: (map(select(.enabled)) | length), total: length}'
}

# cipi notification triggers set [--on=a,b] [--off=c,d] — many at once, one
# write. Every name is checked before anything changes.
_notify_triggers_set() {
    parse_args "$@"
    local on="${ARG_on:-}" off="${ARG_off:-}" t
    [[ -z "$on" && -z "$off" ]] && { error "Usage: cipi notification triggers set [--on=t1,t2] [--off=t3]"; exit 1; }
    local -a ons=() offs=()
    [[ -n "$on" ]] && IFS=',' read -r -a ons <<< "$on"
    [[ -n "$off" ]] && IFS=',' read -r -a offs <<< "$off"
    for t in "${ons[@]}" "${offs[@]}"; do
        [[ -z "$t" ]] && continue
        _notify_trigger_known "$t" || { error "Unknown trigger: ${t} (cipi notification triggers)"; exit 1; }
    done
    _notify_ensure_config
    local patch
    patch=$(jq -n --arg on "$on" --arg off "$off" '
        ([$on | split(",")[] | select(length > 0) | {(.): true}] | add // {})
        + ([$off | split(",")[] | select(length > 0) | {(.): false}] | add // {})')
    vault_read notifications.json | jq --argjson p "$patch" '.triggers += $p' | vault_write notifications.json
    log_action "NOTIFICATION TRIGGERS: on=${on:-none} off=${off:-none}"
    success "Triggers updated: ${#ons[@]} on, ${#offs[@]} off"
}

_notify_triggers_command() {
    local sub="${1:-list}"; shift || true
    if [[ "$sub" == --json ]]; then _notify_triggers_json; return 0; fi
    case "$sub" in
        list|ls|"")
            if [[ "${1:-}" == --json ]]; then _notify_triggers_json; else _notify_list; fi ;;
        set) _notify_triggers_set "$@" ;;
        enable|disable)
            local trigger="${1:-}"
            [[ -z "$trigger" ]] && { error "Usage: cipi notification triggers ${sub} <trigger>"; exit 1; }
            _notify_set_trigger "$trigger" "$( [[ "$sub" == enable ]] && echo true || echo false)"
            success "$( [[ "$sub" == enable ]] && echo Enabled || echo Disabled ): ${trigger} ($(_notify_trigger_label "$trigger"))"
            ;;
        enable-all|all-on)   _notify_enable_all ;;
        disable-all|all-off) _notify_disable_all ;;
        reset) _notify_reset ;;
        *) error "Use: cipi notification triggers [list [--json]|enable <t>|disable <t>|set --on=… --off=…|enable-all|disable-all|reset]"; exit 1 ;;
    esac
}

notifications_command() {
    local sub="${1:-status}"; shift || true
    declare -f alerts_channel_command &>/dev/null || source "${CIPI_LIB}/alerts.sh"
    declare -f smtp_command &>/dev/null || source "${CIPI_LIB}/smtp.sh"
    # --events= on add and update: what the channel takes, set once the
    # channel itself is saved (a refused channel exits before it).
    local _ev_arg="" _ev_set=false a
    local -a _rest=()
    if [[ "$sub" == add || "$sub" == update || "$sub" == edit ]]; then
        for a in "$@"; do
            if [[ "$a" == --events=* ]]; then _ev_arg="${a#--events=}"; _ev_set=true; else _rest+=("$a"); fi
        done
        set -- "${_rest[@]+"${_rest[@]}"}"
        # Checked before the channel is touched: a typo changes nothing.
        if [[ "$_ev_set" == true ]]; then _notify_events_checked "$_ev_arg" >/dev/null; fi
    fi
    case "$sub" in
        status|show) _notify_status "$@" ;;
        channels)    _notify_status "$@" ;;
        events|routes|route) _notify_events_command "$@" ;;
        add)
            if [[ "${1:-}" == smtp ]]; then
                shift
                # An id after the type is accepted and ignored: SMTP is one channel.
                [[ -n "${1:-}" && "${1:-}" != --* ]] && shift
                _smtp_configure "$@"
                if [[ "$_ev_set" == true && -f "$SMTP_CFG" ]]; then _notify_set_events smtp "$_ev_arg"; fi
            else
                local _new_id="${2:-}"
                _alerts_add "$@"
                if [[ "$_ev_set" == true ]]; then _notify_set_events "$_new_id" "$_ev_arg"; fi
            fi ;;
        update|edit)
            local _upd_id="${1:-}"
            if [[ "${1:-}" == smtp ]]; then
                shift
                [[ -f "$SMTP_CFG" ]] || { error "SMTP is not configured: cipi notification add smtp --host= …"; exit 1; }
                # Only --events: nothing else of SMTP to save (nor to test).
                if [[ $# -gt 0 ]]; then
                    # Whatever is not given keeps its value; --host first makes the
                    # call non-interactive even when only --to or --tls changes.
                    _smtp_configure "--host=$(vault_read smtp.json | jq -r '.host // ""')" "$@"
                fi
            elif [[ $# -gt 1 || "$_ev_set" != true ]]; then
                _alerts_update "$@"
            else
                _notify_is_channel "$_upd_id" || { error "Channel '${_upd_id}' not found"; exit 1; }
            fi
            if [[ "$_ev_set" == true ]]; then _notify_set_events "$_upd_id" "$_ev_arg"; fi
            ;;
        remove|rm|delete)
            if [[ "${1:-}" == smtp ]]; then shift; _smtp_delete "$@"; else _alerts_remove "$@"; fi ;;
        test)
            case "${1:-}" in
                smtp) _smtp_test ;;
                all)  _smtp_is_enabled && { _smtp_test || true; }; _alerts_test all ;;
                *)    _alerts_test "${1:-}" ;;
            esac ;;
        enable)  _notify_toggle on "${1:-}" ;;
        disable) _notify_toggle off "${1:-}" ;;
        smtp)    smtp_command "$@" ;;
        triggers|trigger) _notify_triggers_command "$@" ;;
        # The forms of `cipi notifications` before 5.10.0.
        list|ls) _notify_list ;;
        channel)
            alerts_channel_command "$@"
            ;;
        enable-all|all-on)  _notify_enable_all ;;
        disable-all|all-off) _notify_disable_all ;;
        reset) _notify_reset ;;
        *)
            error "Use: cipi notification [status] | add <type> <id> … | update <id> … | remove|test|enable|disable <id> | events [<id> <selectors>] | triggers … | smtp …"
            echo "      types: smtp $(_alert_types)"
            exit 1
            ;;
    esac
}
