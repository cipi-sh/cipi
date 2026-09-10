#!/bin/bash
#############################################
# Cipi — Notification triggers
# Controls which events send email when SMTP is configured.
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
app_db_password_reset|Apps|App DB password reset
alias_add|Domains|Alias added
alias_remove|Domains|Alias removed
www_add|Domains|WWW alias added
www_force_to_root|Domains|WWW force to-root
www_force_from_root|Domains|WWW force from-root
www_clear|Domains|WWW redirect cleared
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
ssl_install|SSL|SSL certificate installed
ssl_force|SSL|HTTP → HTTPS redirect forced
ssl_renew|SSL|SSL certificates renewed
php_install|PHP|PHP version installed
php_switch|PHP|System PHP switched
php_remove|PHP|PHP version removed
php_upgrade|PHP|PHP packages upgraded
nginx_upgrade|Services|Nginx packages upgraded
mariadb_upgrade|Database|MariaDB packages upgraded
pgsql_upgrade|Database|PostgreSQL packages upgraded
valkey_upgrade|Services|Valkey packages upgraded
package_install|Packages|Optional package installed
package_remove|Packages|Optional package removed
db_create|Database|Database created
db_delete|Database|Database deleted
search_install|Search|Meilisearch installed
search_enable|Search|Search enabled for an app
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
crowdsec_enable|Security|CrowdSec enabled
crowdsec_disable|Security|CrowdSec disabled
crowdsec_rescue|Security|CrowdSec rescue token used or rotated
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
reset_db_password|Reset|MariaDB root password reset
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
    val=$(vault_read notifications.json 2>/dev/null | jq -r --arg t "$trigger" '.triggers[$t] // true' 2>/dev/null) || val="true"
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
        smtp_hint="${DIM}  (SMTP not configured — run: cipi smtp configure)${NC}"
    fi

    echo -e "\n${BOLD}Notification triggers${NC}${smtp_hint}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${DIM}  Email is sent only when SMTP is enabled and the trigger is on.${NC}"
    echo -e "${DIM}  Events are always logged to /var/log/cipi/events.log.${NC}\n"

    local cur_cat="" line id cat label on
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        id="${line%%|*}"; line="${line#*|}"
        cat="${line%%|*}"; label="${line#*|}"
        on=$(echo "$cfg" | jq -r --arg t "$id" '.triggers[$t] // true')
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
    echo -e "  ${DIM}Toggle: cipi notifications enable|disable <trigger>${NC}"
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

notifications_command() {
    local sub="${1:-list}"; shift || true
    case "$sub" in
        list|ls|"") _notify_list ;;
        enable)
            local trigger="${1:-}"
            [[ -z "$trigger" ]] && { error "Usage: cipi notifications enable <trigger>"; exit 1; }
            _notify_set_trigger "$trigger" true
            success "Enabled: ${trigger} ($(_notify_trigger_label "$trigger"))"
            ;;
        disable)
            local trigger="${1:-}"
            [[ -z "$trigger" ]] && { error "Usage: cipi notifications disable <trigger>"; exit 1; }
            _notify_set_trigger "$trigger" false
            success "Disabled: ${trigger} ($(_notify_trigger_label "$trigger"))"
            ;;
        enable-all|all-on)  _notify_enable_all ;;
        disable-all|all-off) _notify_disable_all ;;
        reset) _notify_reset ;;
        *)
            error "Use: list enable disable enable-all disable-all reset"
            exit 1
            ;;
    esac
}
