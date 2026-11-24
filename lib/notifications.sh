#!/bin/bash
#############################################
# Cipi — Notifications (cipi notification)
#
# Where they go — channels: SMTP (smtp.json, lib/smtp.sh, unchanged since
# before 5.10.0 and shown here as the channel "smtp"), and the channels of
# lib/alerts.sh (Resend, Amazon SES, Slack, Discord, Mattermost, Google
# Chat, Telegram, ntfy, Pushover, webhook).
# What sends them — triggers: this file. Every trigger reaches every
# enabled channel.
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
    echo -e "${DIM}  A trigger that is on reaches every enabled channel: SMTP, Resend, SES, Slack,${NC}"
    echo -e "${DIM}  Discord, Mattermost, Google Chat, Telegram, ntfy, Pushover, webhook (cipi notification).${NC}"
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
            host: (.host // null), port: ((.port // "587") | tostring), tls: (.tls != false)}' <<< "$_sj"
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
            --arg types "smtp $(_alert_types)" \
            '{channels: ((if $s == null then [] else [$s] end) + $c), triggers: {enabled: $on, total: $t},
              types: ($types | split(" "))}'
        return 0
    fi
    echo -e "\n${BOLD}Notifications${NC} ${DIM}— every enabled trigger reaches every enabled channel${NC}"
    echo -e "\n${BOLD}SMTP${NC}"
    if [[ -f "$SMTP_CFG" ]]; then
        local _sj; _sj=$(vault_read smtp.json)
        local st="${YELLOW}disabled${NC}"; [[ "$(jq -r '.enabled // false' <<< "$_sj")" == true ]] && st="${GREEN}enabled${NC}"
        echo -e "  ${st}  $(jq -r '.host' <<< "$_sj"):$(jq -r '.port // 587' <<< "$_sj")  $(jq -r '.from // ""' <<< "$_sj") → $(jq -r '.to // ""' <<< "$_sj")"
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
         | {id: .[0], category: .[1], label: (.[2:] | join("|")),
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
    case "$sub" in
        status|show) _notify_status "$@" ;;
        channels)    _notify_status "$@" ;;
        add)
            if [[ "${1:-}" == smtp ]]; then
                shift
                # An id after the type is accepted and ignored: SMTP is one channel.
                [[ -n "${1:-}" && "${1:-}" != --* ]] && shift
                _smtp_configure "$@"
            else
                _alerts_add "$@"
            fi ;;
        update|edit)
            if [[ "${1:-}" == smtp ]]; then
                shift
                # Whatever is not given keeps its value; --host first makes the
                # call non-interactive even when only --to or --tls changes.
                [[ -f "$SMTP_CFG" ]] || { error "SMTP is not configured: cipi notification add smtp --host= …"; exit 1; }
                _smtp_configure "--host=$(vault_read smtp.json | jq -r '.host // ""')" "$@"
            else
                _alerts_update "$@"
            fi ;;
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
            error "Use: cipi notification [status] | add <type> <id> … | update <id> … | remove|test|enable|disable <id> | triggers … | smtp …"
            echo "      types: smtp $(_alert_types)"
            exit 1
            ;;
    esac
}
