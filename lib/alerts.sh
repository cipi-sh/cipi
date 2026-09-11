#!/bin/bash
#############################################
# Cipi — Alert channels (Slack, Discord, ntfy, generic webhook)
#
# Channels fan out from cipi_notify(): configure once and every trigger
# (deploy, backup, scan, monitor, ...) reaches chat as well as email.
# Delivery is best-effort and never blocks the caller — a slow webhook
# must not slow down a deploy or a cron run.
#############################################

[[ -z "${ALERTS_CFG:-}" ]] && readonly ALERTS_CFG="${CIPI_CONFIG}/alerts.json"

_alert_types() { echo "slack discord ntfy telegram webhook"; }

_alert_type_known() {
    local t="${1:-}"
    [[ " $(_alert_types) " == *" $t "* ]]
}

_alerts_ensure_config() {
    if [[ ! -f "$ALERTS_CFG" ]]; then
        echo '{"channels":[]}' | vault_write alerts.json
    fi
}

# Triggers that escalate an ntfy channel to high priority and get a
# rotating-light tag. Recovery and routine events stay quiet.
_alert_trigger_urgent() {
    case "${1:-}" in
        ssh_login|sudo|su|scan_hit|scan_integrity|crowdsec_rescue|\
backup_fail|backup_stale|deploy_fail|deploy_health_fail|health_fail|\
monitor_services|monitor_workers|monitor_fs|monitor_disk|monitor_http_5xx)
            return 0 ;;
        *) return 1 ;;
    esac
}

_alert_http_fail() {
    local id="$1" type="$2"
    log_event "ALERT CHANNEL FAIL: ${id} (${type})"
    return 0
}

# _alert_deliver_channel <channel-json> <subject> <body> [trigger]
_alert_deliver_channel() {
    local ch="$1" subject="$2" body="$3" trigger="${4:-}"
    local type id url enabled
    type=$(jq -r '.type // ""' <<<"$ch")
    id=$(jq -r '.id // "?"' <<<"$ch")
    url=$(jq -r '.url // ""' <<<"$ch")
    # NB: jq's `// true` treats false as empty — `.enabled != false` is the
    # correct "default true" for an explicitly disabled channel.
    enabled=$(jq -r '.enabled != false' <<<"$ch")
    [[ "$enabled" == "true" ]] || return 0
    # telegram carries bot token + chat_id instead of a webhook URL
    [[ "$type" != "telegram" && -z "$url" ]] && return 0

    # cipi_notify bodies carry literal "\n" sequences (email renders them via
    # printf %b); chat channels need real newlines.
    body="${body//\\n/$'\n'}"

    case "$type" in
        slack)
            local payload
            payload=$(jq -n --arg t "*${subject}*" --arg b "$body" '{text: ($t + "\n" + $b)}')
            curl -fsS -o /dev/null --max-time 5 -H 'Content-Type: application/json' \
                -d "$payload" "$url" 2>/dev/null || { _alert_http_fail "$id" "$type"; return 0; }
            ;;
        discord)
            local text payload
            text="**${subject}**"$'\n'"${body}"
            text="${text:0:1990}"   # Discord caps content at 2000 chars
            payload=$(jq -n --arg c "$text" '{content: $c}')
            curl -fsS -o /dev/null --max-time 5 -H 'Content-Type: application/json' \
                -d "$payload" "$url" 2>/dev/null || { _alert_http_fail "$id" "$type"; return 0; }
            ;;
        ntfy)
            local prio tags
            prio=$(jq -r '.priority // "default"' <<<"$ch")
            if [[ "$prio" == "default" ]] && _alert_trigger_urgent "$trigger"; then
                prio="high"
            fi
            tags="cipi"
            _alert_trigger_urgent "$trigger" && tags="${tags},rotating_light"
            [[ "$trigger" == "monitor_ok" ]] && tags="${tags},white_check_mark"
            # Title is an HTTP header: a newline in a subject would corrupt the
            # request. Body goes in on stdin — curl's -d treats a leading "@"
            # as "read this file", which would silently swallow the alert.
            local title="${subject//[$'\n\r']/ }"
            printf '%s' "$body" | curl -fsS -o /dev/null --max-time 5 \
                -H "Title: ${title}" -H "Priority: ${prio}" -H "Tags: ${tags}" \
                --data-binary @- "$url" 2>/dev/null || { _alert_http_fail "$id" "$type"; return 0; }
            ;;
        telegram)
            local token chat_id text payload
            token=$(jq -r '.token // ""' <<<"$ch")
            chat_id=$(jq -r '.chat_id // ""' <<<"$ch")
            [[ -z "$token" || -z "$chat_id" ]] && return 0
            # Plain text, no parse_mode: Markdown would break on the first
            # underscore in a hostname or path inside the alert body.
            text="${subject}"$'\n\n'"${body}"
            text="${text:0:4090}"   # Telegram caps messages at 4096 chars
            payload=$(jq -n --arg c "$chat_id" --arg t "$text" \
                '{chat_id: $c, text: $t, disable_web_page_preview: true}')
            curl -fsS -o /dev/null --max-time 5 -H 'Content-Type: application/json' \
                -d "$payload" "https://api.telegram.org/bot${token}/sendMessage" 2>/dev/null \
                || { _alert_http_fail "$id" "$type"; return 0; }
            ;;
        webhook)
            local payload
            payload=$(jq -n \
                --arg server "$(hostname)" --arg trigger "$trigger" \
                --arg subject "$subject" --arg body "$body" \
                --argjson ts "$(date +%s)" \
                '{server:$server, trigger:$trigger, subject:$subject, body:$body, ts:$ts}')
            curl -fsS -o /dev/null --max-time 5 -H 'Content-Type: application/json' \
                -d "$payload" "$url" 2>/dev/null || { _alert_http_fail "$id" "$type"; return 0; }
            ;;
        *)
            return 0
            ;;
    esac
    return 0
}

# _alerts_deliver <subject> <body> [trigger] — fan out to every enabled channel.
_alerts_deliver() {
    local subject="$1" body="$2" trigger="${3:-}"
    [[ -f "$ALERTS_CFG" ]] || return 0
    local channels
    channels=$(vault_read alerts.json 2>/dev/null | jq -c '.channels[]?' 2>/dev/null) || return 0
    [[ -z "$channels" ]] && return 0
    local ch
    while IFS= read -r ch; do
        [[ -z "$ch" ]] && continue
        _alert_deliver_channel "$ch" "$subject" "$body" "$trigger" || true
    done <<< "$channels"
    return 0
}

# ── CLI ────────────────────────────────────────────────────────

_alert_id_valid() {
    [[ "${1:-}" =~ ^[a-z0-9][a-z0-9-]*$ ]]
}

# Mask the secret part of a webhook URL: keep scheme, host and first path
# segment (https://hooks.slack.com/services/***). An ntfy topic is the whole
# path, so keep at least the host — hiding that names no channel at all.
_alert_url_mask() {
    local url="$1"
    if [[ "$url" =~ ^(https?://[^/]+/[^/]+/) ]]; then
        echo "${BASH_REMATCH[1]}***"
    elif [[ "$url" =~ ^(https?://[^/]+/) ]]; then
        echo "${BASH_REMATCH[1]}***"
    else
        echo "***"
    fi
}

_alerts_add() {
    local type="${1:-}" id="${2:-}"; shift 2 || true
    parse_args "$@"
    if ! _alert_type_known "$type"; then
        error "Unknown channel type: ${type:-<missing>} (valid: $(_alert_types))"
        exit 1
    fi
    if ! _alert_id_valid "$id"; then
        error "Invalid channel id '${id}' — lowercase letters, digits, dashes"
        exit 1
    fi
    local url="${ARG_url:-}" priority="${ARG_priority:-default}"
    local token="${ARG_token:-}" chat_id="${ARG_chat_id:-}"
    if [[ "$type" == "telegram" ]]; then
        [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] \
            || { error "--token must be the bot token from @BotFather (123456:ABC-DEF…)"; exit 1; }
        [[ "$chat_id" =~ ^-?[0-9]+$ ]] \
            || { error "--chat-id must be numeric (negative for groups); send /start to the bot, then check getUpdates"; exit 1; }
    else
        [[ "$url" =~ ^https?:// ]] || { error "--url must start with http:// or https://"; exit 1; }
    fi
    if [[ "$type" == "ntfy" ]]; then
        [[ "$priority" =~ ^(min|low|default|high|urgent|[1-5])$ ]] \
            || { error "--priority must be min|low|default|high|urgent (or 1-5)"; exit 1; }
    fi

    _alerts_ensure_config
    if vault_read alerts.json | jq -e --arg id "$id" '.channels[] | select(.id == $id)' >/dev/null; then
        error "Channel '${id}' already exists — remove it first: cipi notifications channel remove ${id}"
        exit 1
    fi

    if [[ "$type" == "telegram" ]]; then
        vault_read alerts.json | jq \
            --arg id "$id" --arg type "$type" --arg token "$token" --arg chat_id "$chat_id" \
            '.channels += [{id:$id, type:$type, token:$token, chat_id:$chat_id, enabled:true}]' \
            | vault_write alerts.json
    else
        vault_read alerts.json | jq \
            --arg id "$id" --arg type "$type" --arg url "$url" --arg priority "$priority" \
            '.channels += [{id:$id, type:$type, url:$url, priority:$priority, enabled:true}]' \
            | vault_write alerts.json
    fi
    log_action "ALERT CHANNEL ADD: ${id} (${type})"
    success "Channel '${id}' (${type}) added — every notification trigger now reaches it"
    info "Test it with: cipi notifications channel test ${id}"
}

_alerts_remove() {
    local id="${1:-}"
    [[ -z "$id" ]] && { error "Usage: cipi notifications channel remove <id>"; exit 1; }
    _alerts_ensure_config
    if ! vault_read alerts.json | jq -e --arg id "$id" '.channels[] | select(.id == $id)' >/dev/null; then
        error "Channel '${id}' not found"
        exit 1
    fi
    vault_read alerts.json | jq --arg id "$id" '.channels |= map(select(.id != $id))' | vault_write alerts.json
    log_action "ALERT CHANNEL REMOVE: ${id}"
    success "Channel '${id}' removed"
}

_alerts_set_enabled() {
    local id="$1" enabled="$2"
    _alerts_ensure_config
    if ! vault_read alerts.json | jq -e --arg id "$id" '.channels[] | select(.id == $id)' >/dev/null; then
        error "Channel '${id}' not found"
        exit 1
    fi
    vault_read alerts.json | jq --arg id "$id" --argjson e "$enabled" \
        '.channels |= map(if .id == $id then .enabled = $e else . end)' | vault_write alerts.json
    if [[ "$enabled" == "true" ]]; then
        success "Channel '${id}' enabled"
    else
        success "Channel '${id}' disabled"
    fi
}

_alerts_list() {
    parse_args "$@"
    _alerts_ensure_config
    local cfg; cfg=$(vault_read alerts.json)

    if [[ "${ARG_json:-}" == "true" ]]; then
        echo "$cfg" | jq '{channels: .channels}'
        return 0
    fi

    echo -e "\n${BOLD}Alert channels${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local n; n=$(echo "$cfg" | jq '.channels | length')
    if [[ "$n" == "0" ]]; then
        echo -e "  ${DIM}No channels. Alerts go by email only (if SMTP is configured).${NC}"
        echo ""
        echo -e "  Add one:"
        echo -e "    ${CYAN}cipi notifications channel add slack ops --url=https://hooks.slack.com/services/…${NC}"
        echo -e "    ${CYAN}cipi notifications channel add discord ops --url=https://discord.com/api/webhooks/…${NC}"
        echo -e "    ${CYAN}cipi notifications channel add telegram ops --token=<bot-token> --chat-id=<id>${NC}"
        echo -e "    ${CYAN}cipi notifications channel add ntfy phone --url=https://ntfy.sh/<topic> --priority=high${NC}"
        echo ""
        return 0
    fi
    local ch id type enabled url priority target
    while IFS= read -r ch; do
        [[ -z "$ch" ]] && continue
        id=$(jq -r '.id' <<<"$ch"); type=$(jq -r '.type' <<<"$ch")
        enabled=$(jq -r '.enabled != false' <<<"$ch")
        priority=$(jq -r '.priority // ""' <<<"$ch")
        if [[ "$type" == "telegram" ]]; then
            # Show the bot token prefix only — it is a full-access secret.
            target="bot $(jq -r '.token // ""' <<<"$ch" | cut -c1-8)… → chat $(jq -r '.chat_id // "?"' <<<"$ch")"
        else
            target=$(_alert_url_mask "$(jq -r '.url // ""' <<<"$ch")")
        fi
        if [[ "$enabled" == "true" ]]; then
            printf "  ${GREEN}●${NC} %-14s %-8s %s" "$id" "$type" "$target"
        else
            printf "  ${DIM}○ %-14s %-8s %s${NC}" "$id" "$type" "$target"
        fi
        [[ "$type" == "ntfy" && -n "$priority" && "$priority" != "default" ]] && printf "  ${DIM}priority=%s${NC}" "$priority"
        echo
    done < <(echo "$cfg" | jq -c '.channels[]')
    echo ""
    echo -e "  ${DIM}Manage: cipi notifications channel add|remove|enable|disable|test${NC}"
    echo ""
}

_alerts_test() {
    local id="${1:-}"
    [[ -z "$id" ]] && { error "Usage: cipi notifications channel test <id|all>"; exit 1; }
    _alerts_ensure_config
    local cfg; cfg=$(vault_read alerts.json)
    local subject="Cipi test alert on $(hostname)"
    local body="Test notification from Cipi.\nServer: $(hostname)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')"

    if [[ "$id" == "all" ]]; then
        local n; n=$(echo "$cfg" | jq '[.channels[] | select(.enabled != false)] | length')
        [[ "$n" == "0" ]] && { error "No enabled channels"; exit 1; }
        _alerts_deliver "$subject" "$body" ""
        success "Test sent to ${n} channel(s)"
        return 0
    fi

    local ch
    ch=$(echo "$cfg" | jq -c --arg id "$id" '.channels[] | select(.id == $id)')
    [[ -z "$ch" ]] && { error "Channel '${id}' not found"; exit 1; }
    step "Sending test alert to '${id}'..."
    _alert_deliver_channel "$ch" "$subject" "$body" ""
    success "Test sent to '${id}' — check the channel; failures are logged in /var/log/cipi/events.log"
}

alerts_channel_command() {
    local sub="${1:-list}"; shift || true
    case "$sub" in
        add)            _alerts_add "$@" ;;
        remove|rm)      _alerts_remove "$@" ;;
        list|ls|"")     _alerts_list "$@" ;;
        test)           _alerts_test "${1:-}" ;;
        enable)         [[ -n "${1:-}" ]] && _alerts_set_enabled "$1" true  || { error "Usage: cipi notifications channel enable <id>"; exit 1; } ;;
        disable)        [[ -n "${1:-}" ]] && _alerts_set_enabled "$1" false || { error "Usage: cipi notifications channel disable <id>"; exit 1; } ;;
        *)
            error "Use: channel add <slack|discord|ntfy|telegram|webhook> <id> --url= [--priority=] | telegram: --token= --chat-id= | remove|list|test|enable|disable"
            exit 1
            ;;
    esac
}
