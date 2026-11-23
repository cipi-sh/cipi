#!/bin/bash
#############################################
# Cipi — Notification channels (cipi notification)
#
#   email:  resend (API), ses (Amazon SES API v2, SigV4-signed) — SMTP is
#           smtp.json, lib/smtp.sh, and shows up here as the channel "smtp"
#   chat:   slack, discord, mattermost, googlechat, telegram
#   push:   ntfy, pushover
#   other:  webhook (JSON, optionally HMAC-signed)
#
# Channels fan out from cipi_notify(): configure once and every trigger
# (deploy, backup, scan, monitor, ...) reaches every enabled channel.
# Secrets (API keys, bot tokens, AWS keys) live in alerts.json, which the
# vault encrypts, and are never printed back.
# Delivery is best-effort and never blocks the caller — a slow webhook
# must not slow down a deploy or a cron run.
#############################################

[[ -z "${ALERTS_CFG:-}" ]] && readonly ALERTS_CFG="${CIPI_CONFIG}/alerts.json"

_alert_types() { echo "slack discord mattermost googlechat telegram ntfy pushover webhook resend ses"; }

# Email channels: they carry a sender and recipients.
_alert_type_is_email() { [[ "${1:-}" == resend || "${1:-}" == ses ]]; }
# Channels that are an incoming-webhook URL and nothing else.
_alert_type_is_url() { [[ " slack discord mattermost googlechat ntfy webhook " == *" ${1:-} "* ]]; }

# "a@x.com, b@y.com" → JSON array; fails on anything that is not an address.
_alert_emails_json() {
    local list="${1:-}" e out="[]"
    IFS=',' read -r -a _ae <<< "$list"
    for e in "${_ae[@]}"; do
        e="${e// /}"
        [[ -z "$e" ]] && continue
        [[ "$e" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || return 1
        out=$(jq -c --arg e "$e" '. + [$e]' <<< "$out")
    done
    [[ "$out" != "[]" ]] || return 1
    echo "$out"
}

# ── Amazon SES (API v2, Signature Version 4) ──────────────────
_alert_hmac() {   # <key|hexkey:...> <data> → hex
    printf '%s' "$2" | openssl dgst -sha256 -mac HMAC -macopt "$1" 2>/dev/null | awk '{ print $NF }'
}
_alert_sha256() { printf '%s' "$1" | openssl dgst -sha256 2>/dev/null | awk '{ print $NF }'; }

# _alert_ses_send <channel-json> <subject> <body>
_alert_ses_send() {
    local ch="$1" subject="$2" body="$3"
    local region ak sk from to host payload amzdate day creq sts k sig scope
    region=$(jq -r '.region // ""' <<<"$ch"); ak=$(jq -r '.access_key // ""' <<<"$ch")
    sk=$(jq -r '.secret_key // ""' <<<"$ch"); from=$(jq -r '.from // ""' <<<"$ch")
    to=$(jq -c '.to // []' <<<"$ch")
    [[ -n "$region" && -n "$ak" && -n "$sk" && -n "$from" && "$to" != "[]" ]] || return 1
    host="email.${region}.amazonaws.com"
    payload=$(jq -nc --arg f "$from" --argjson t "$to" --arg s "$subject" --arg b "$body" \
        '{FromEmailAddress: $f, Destination: {ToAddresses: $t},
          Content: {Simple: {Subject: {Data: $s, Charset: "UTF-8"}, Body: {Text: {Data: $b, Charset: "UTF-8"}}}}}')
    amzdate=$(date -u '+%Y%m%dT%H%M%SZ'); day="${amzdate:0:8}"
    scope="${day}/${region}/ses/aws4_request"
    creq="POST"$'\n'"/v2/email/outbound-emails"$'\n'""$'\n'"content-type:application/json"$'\n'"host:${host}"$'\n'"x-amz-date:${amzdate}"$'\n'""$'\n'"content-type;host;x-amz-date"$'\n'"$(_alert_sha256 "$payload")"
    sts="AWS4-HMAC-SHA256"$'\n'"${amzdate}"$'\n'"${scope}"$'\n'"$(_alert_sha256 "$creq")"
    k=$(_alert_hmac "key:AWS4${sk}" "$day")
    k=$(_alert_hmac "hexkey:${k}" "$region")
    k=$(_alert_hmac "hexkey:${k}" ses)
    k=$(_alert_hmac "hexkey:${k}" aws4_request)
    sig=$(_alert_hmac "hexkey:${k}" "$sts")
    [[ -n "$sig" ]] || return 1
    printf '%s' "$payload" | curl -fsS -o /dev/null --max-time 10 -X POST \
        -H 'Content-Type: application/json' -H "X-Amz-Date: ${amzdate}" \
        -H "Authorization: AWS4-HMAC-SHA256 Credential=${ak}/${scope}, SignedHeaders=content-type;host;x-amz-date, Signature=${sig}" \
        --data-binary @- "https://${host}/v2/email/outbound-emails"
}

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
    _ALERT_LAST_FAIL="${id}"
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
    # Only the URL channels need a URL; the others carry keys and tokens.
    _alert_type_is_url "$type" && [[ -z "$url" ]] && return 0

    # cipi_notify bodies carry literal "\n" sequences (email renders them via
    # printf %b); chat channels need real newlines.
    body="${body//\\n/$'\n'}"

    case "$type" in
        slack|mattermost)
            # Mattermost's incoming webhooks take Slack's payload.
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
        googlechat)
            local payload
            payload=$(jq -n --arg t "*${subject}*" --arg b "$body" '{text: ($t + "\n" + $b)}')
            curl -fsS -o /dev/null --max-time 5 -H 'Content-Type: application/json; charset=UTF-8' \
                -d "$payload" "$url" 2>/dev/null || { _alert_http_fail "$id" "$type"; return 0; }
            ;;
        pushover)
            local token user prio=0
            token=$(jq -r '.token // ""' <<<"$ch"); user=$(jq -r '.user // ""' <<<"$ch")
            [[ -z "$token" || -z "$user" ]] && return 0
            _alert_trigger_urgent "$trigger" && prio=1
            curl -fsS -o /dev/null --max-time 5 \
                --form-string "token=${token}" --form-string "user=${user}" \
                --form-string "title=${subject:0:250}" --form-string "message=${body:0:1020}" \
                --form-string "priority=${prio}" \
                https://api.pushover.net/1/messages.json 2>/dev/null || { _alert_http_fail "$id" "$type"; return 0; }
            ;;
        resend)
            local key from to payload
            key=$(jq -r '.api_key // ""' <<<"$ch"); from=$(jq -r '.from // ""' <<<"$ch"); to=$(jq -c '.to // []' <<<"$ch")
            [[ -z "$key" || -z "$from" || "$to" == "[]" ]] && return 0
            payload=$(jq -nc --arg f "$from" --argjson t "$to" --arg s "$subject" --arg b "$body" \
                '{from: $f, to: $t, subject: $s, text: $b}')
            # The key on stdin (-H @-): not in the process list.
            printf 'Authorization: Bearer %s\n' "$key" | curl -fsS -o /dev/null --max-time 10 \
                -H @- -H 'Content-Type: application/json' -d "$payload" https://api.resend.com/emails 2>/dev/null \
                || { _alert_http_fail "$id" "$type"; return 0; }
            ;;
        ses)
            _alert_ses_send "$ch" "$subject" "$body" 2>/dev/null || { _alert_http_fail "$id" "$type"; return 0; }
            ;;
        webhook)
            # With a secret, the receiver can tell the request is ours:
            # X-Cipi-Signature: sha256=<HMAC-SHA256 of the body, hex>.
            local payload secret sig
            payload=$(jq -nc \
                --arg server "$(hostname)" --arg trigger "$trigger" \
                --arg subject "$subject" --arg body "$body" \
                --argjson ts "$(date +%s)" \
                '{server:$server, trigger:$trigger, subject:$subject, body:$body, ts:$ts}')
            secret=$(jq -r '.secret // ""' <<<"$ch")
            if [[ -n "$secret" ]]; then
                sig=$(_alert_hmac "key:${secret}" "$payload")
                printf '%s' "$payload" | curl -fsS -o /dev/null --max-time 5 -H 'Content-Type: application/json' \
                    -H "X-Cipi-Signature: sha256=${sig}" --data-binary @- "$url" 2>/dev/null \
                    || { _alert_http_fail "$id" "$type"; return 0; }
            else
                printf '%s' "$payload" | curl -fsS -o /dev/null --max-time 5 -H 'Content-Type: application/json' \
                    --data-binary @- "$url" 2>/dev/null || { _alert_http_fail "$id" "$type"; return 0; }
            fi
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

# A secret given on the command line, or asked for on a terminal (not echoed).
_alert_secret() {   # <value from flag> <prompt>
    local v="${1:-}"
    if [[ -z "$v" && -t 0 ]]; then
        read -r -s -p "  ${2}: " v; echo "" >&2
    fi
    printf '%s' "$v"
}

_alerts_add() {
    local type="${1:-}" id="${2:-}"; shift 2 || true
    parse_args "$@"
    if ! _alert_type_known "$type"; then
        error "Unknown channel type: ${type:-<missing>} (valid: smtp $(_alert_types))"
        exit 1
    fi
    if ! _alert_id_valid "$id" || [[ "$id" == smtp ]]; then
        error "Invalid channel id '${id}' — lowercase letters, digits, dashes (smtp is the SMTP channel)"
        exit 1
    fi
    _alerts_ensure_config
    if vault_read alerts.json | jq -e --arg id "$id" '.channels[] | select(.id == $id)' >/dev/null; then
        error "Channel '${id}' already exists — change it with: cipi notification update ${id} …"
        exit 1
    fi

    _alerts_build_channel "$type" "$id"
    vault_read alerts.json | jq --argjson ch "$_ALERT_CH" '.channels += [$ch]' | vault_write alerts.json
    log_action "ALERT CHANNEL ADD: ${id} (${type})"
    success "Channel '${id}' (${type}) added — every notification trigger now reaches it"
    info "Test it with: cipi notification test ${id}"
}

# cipi notification update <id> [flags] — change a channel in place. Flags
# left out keep their value, secrets included, so a form that never shows a
# token back can still change the recipients. --clear-secret drops the
# signing secret of a webhook. The type of a channel does not change.
_alerts_update() {
    local id="${1:-}"; shift || true
    [[ -z "$id" ]] && { error "Usage: cipi notification update <id> [--url= --token= …]"; exit 1; }
    parse_args "$@"
    _alerts_ensure_config
    local cur
    cur=$(vault_read alerts.json | jq -c --arg id "$id" '.channels[] | select(.id == $id)')
    [[ -z "$cur" ]] && { error "Channel '${id}' not found"; exit 1; }
    local type enabled
    type=$(jq -r '.type' <<<"$cur")
    enabled=$(jq -r '.enabled != false' <<<"$cur")
    [[ -n "${ARG_type:-}" && "${ARG_type}" != "$type" ]] && { error "The type of '${id}' is ${type}; remove it and add a new channel to change it"; exit 1; }

    # Every value not given keeps the stored one.
    local k v
    for k in url priority secret token chat_id user api_key from region access_key secret_key; do
        local var="ARG_${k}"
        if [[ -z "${!var:-}" ]]; then
            v=$(jq -r --arg k "$k" '.[$k] // empty' <<<"$cur")
            [[ -n "$v" ]] && printf -v "$var" '%s' "$v"
        fi
    done
    [[ -z "${ARG_to:-}" ]] && ARG_to=$(jq -r '(.to // []) | if type == "array" then join(",") else . end' <<<"$cur")
    [[ "${ARG_clear_secret:-}" == true ]] && ARG_secret=""

    _alerts_build_channel "$type" "$id"
    local ch
    ch=$(jq -c --argjson e "$enabled" '.enabled = $e' <<<"$_ALERT_CH")
    vault_read alerts.json | jq --arg id "$id" --argjson ch "$ch" \
        '.channels |= map(if .id == $id then $ch else . end)' | vault_write alerts.json
    log_action "ALERT CHANNEL UPDATE: ${id} (${type})"
    success "Channel '${id}' (${type}) updated"
}

# Validates the ARG_* of a channel of <type> and leaves it, as JSON, in
# _ALERT_CH. Not in a subshell: a refused value exits the command.
_alerts_build_channel() {
    local type="$1" id="$2"
    local ch url="${ARG_url:-}" to_json
    case "$type" in
        telegram)
            local token chat_id="${ARG_chat_id:-}"
            token=$(_alert_secret "${ARG_token:-}" "Bot token (from @BotFather)")
            [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] \
                || { error "--token must be the bot token from @BotFather (123456:ABC-DEF…)"; exit 1; }
            [[ "$chat_id" =~ ^-?[0-9]+$ ]] \
                || { error "--chat-id must be numeric (negative for groups); send /start to the bot, then check getUpdates"; exit 1; }
            ch=$(jq -nc --arg id "$id" --arg token "$token" --arg c "$chat_id" '{id:$id, type:"telegram", token:$token, chat_id:$c, enabled:true}')
            ;;
        pushover)
            local token user="${ARG_user:-}"
            token=$(_alert_secret "${ARG_token:-}" "Pushover application token")
            [[ "$token" =~ ^[A-Za-z0-9]{30}$ ]] || { error "--token must be the 30-character application token of pushover.net"; exit 1; }
            [[ "$user" =~ ^[A-Za-z0-9]{30}$ ]] || { error "--user must be the 30-character user (or group) key of pushover.net"; exit 1; }
            ch=$(jq -nc --arg id "$id" --arg t "$token" --arg u "$user" '{id:$id, type:"pushover", token:$t, user:$u, enabled:true}')
            ;;
        resend)
            local key
            key=$(_alert_secret "${ARG_api_key:-}" "Resend API key (re_…)")
            [[ "$key" =~ ^re_[A-Za-z0-9_]+$ ]] || { error "--api-key must be a Resend API key (re_…)"; exit 1; }
            [[ "${ARG_from:-}" == *@* ]] || { error "--from: a sender on a domain verified in Resend (\"Cipi <alerts@example.com>\" or alerts@example.com)"; exit 1; }
            to_json=$(_alert_emails_json "${ARG_to:-}") || { error "--to: one or more addresses, comma-separated"; exit 1; }
            ch=$(jq -nc --arg id "$id" --arg k "$key" --arg f "${ARG_from}" --argjson t "$to_json" '{id:$id, type:"resend", api_key:$k, from:$f, to:$t, enabled:true}')
            ;;
        ses)
            local region="${ARG_region:-}" ak="${ARG_access_key:-}" sk
            [[ "$region" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] || { error "--region: the AWS region of SES, e.g. eu-west-1"; exit 1; }
            [[ "$ak" =~ ^(AKIA|ASIA)[A-Z0-9]{12,}$ ]] || { error "--access-key: an AWS access key id (AKIA…) of a user allowed ses:SendEmail"; exit 1; }
            sk=$(_alert_secret "${ARG_secret_key:-}" "AWS secret access key")
            [[ ${#sk} -ge 30 && "$sk" =~ ^[A-Za-z0-9/+=]+$ ]] || { error "--secret-key: the AWS secret access key"; exit 1; }
            [[ "${ARG_from:-}" == *@* ]] || { error "--from: an identity verified in SES"; exit 1; }
            to_json=$(_alert_emails_json "${ARG_to:-}") || { error "--to: one or more addresses, comma-separated (verified too, while SES is in its sandbox)"; exit 1; }
            ch=$(jq -nc --arg id "$id" --arg r "$region" --arg a "$ak" --arg s "$sk" --arg f "${ARG_from}" --argjson t "$to_json" \
                '{id:$id, type:"ses", region:$r, access_key:$a, secret_key:$s, from:$f, to:$t, enabled:true}')
            ;;
        *)
            [[ "$url" =~ ^https:// || ( "$url" =~ ^http:// && ( "$type" == ntfy || "$type" == webhook ) ) ]] \
                || { error "--url must start with https:// (http:// only for ntfy and webhook)"; exit 1; }
            local priority="${ARG_priority:-default}" secret="${ARG_secret:-}"
            if [[ "$type" == "ntfy" ]]; then
                [[ "$priority" =~ ^(min|low|default|high|urgent|[1-5])$ ]] \
                    || { error "--priority must be min|low|default|high|urgent (or 1-5)"; exit 1; }
            fi
            if [[ -n "$secret" && "$type" != webhook ]]; then error "--secret is for webhook channels"; exit 1; fi
            ch=$(jq -nc --arg id "$id" --arg type "$type" --arg url "$url" --arg p "$priority" --arg s "$secret" \
                '{id:$id, type:$type, url:$url, priority:$p, enabled:true} + (if $s == "" then {} else {secret:$s} end)')
            ;;
    esac
    _ALERT_CH="$ch"
}

_alerts_remove() {
    local id="${1:-}"
    [[ -z "$id" ]] && { error "Usage: cipi notification remove <id>"; exit 1; }
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
        # Secrets never leave the vault: a key is reported as set, not shown.
        echo "$cfg" | jq '{channels: [.channels[] | with_entries(
            if (.key | IN("token", "api_key", "secret_key", "secret")) then .value = (.value != "") | .key = (.key + "_set")
            elif .key == "url" then .value = (.value | sub("^(?<a>https?://[^/]+/)(.*)$"; "\(.a)***"))
            else . end)]}'
        return 0
    fi

    echo -e "\n${BOLD}Alert channels${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local n; n=$(echo "$cfg" | jq '.channels | length')
    if [[ "$n" == "0" ]]; then
        echo -e "  ${DIM}No channels besides SMTP (cipi notification add smtp).${NC}"
        echo ""
        echo -e "  Add one:"
        echo -e "    ${CYAN}cipi notification add slack ops --url=https://hooks.slack.com/services/…${NC}"
        echo -e "    ${CYAN}cipi notification add discord ops --url=https://discord.com/api/webhooks/…${NC}"
        echo -e "    ${CYAN}cipi notification add telegram ops --token=<bot-token> --chat-id=<id>${NC}"
        echo -e "    ${CYAN}cipi notification add ntfy phone --url=https://ntfy.sh/<topic> --priority=high${NC}"
        echo -e "    ${CYAN}cipi notification add resend mail --api-key=re_… --from=alerts@example.com --to=ops@example.com${NC}"
        echo -e "    ${CYAN}cipi notification add ses mail --region=eu-west-1 --access-key=AKIA… --from=… --to=…${NC}"
        echo ""
        return 0
    fi
    local ch id type enabled url priority target
    tbl_start
    while IFS= read -r ch; do
        [[ -z "$ch" ]] && continue
        id=$(jq -r '.id' <<<"$ch"); type=$(jq -r '.type' <<<"$ch")
        enabled=$(jq -r '.enabled != false' <<<"$ch")
        priority=$(jq -r '.priority // ""' <<<"$ch")
        case "$type" in
            telegram)
                # Show the bot token prefix only — it is a full-access secret.
                target="bot $(jq -r '.token // ""' <<<"$ch" | cut -c1-8)… → chat $(jq -r '.chat_id // "?"' <<<"$ch")" ;;
            pushover) target="user $(jq -r '.user // ""' <<<"$ch" | cut -c1-6)…" ;;
            resend)   target="$(jq -r '.from' <<<"$ch") → $(jq -r '.to | join(", ")' <<<"$ch")" ;;
            ses)      target="$(jq -r '.region' <<<"$ch"): $(jq -r '.from' <<<"$ch") → $(jq -r '.to | join(", ")' <<<"$ch")" ;;
            *)        target=$(_alert_url_mask "$(jq -r '.url // ""' <<<"$ch")")
                      [[ "$type" == webhook && -n "$(jq -r '.secret // ""' <<<"$ch")" ]] && target="${target}  ${DIM}signed${NC}" ;;
        esac
        local extra=""
        [[ "$type" == "ntfy" && -n "$priority" && "$priority" != "default" ]] && extra="  ${DIM}priority=${priority}${NC}"
        if [[ "$enabled" == "true" ]]; then
            tbl_row "${GREEN}●${NC}" "$id" "$type" "${target}${extra}"
        else
            tbl_row "${DIM}○" "$id" "$type" "${target}${NC}${extra}"
        fi
    done < <(echo "$cfg" | jq -c '.channels[]')
    tbl_print
    echo ""
    echo -e "  ${DIM}Manage: cipi notification add|remove|enable|disable|test${NC}"
    echo ""
}

_alerts_test() {
    local id="${1:-}"
    [[ -z "$id" ]] && { error "Usage: cipi notification test <id|all>"; exit 1; }
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
    # A test reaches a disabled channel too: that is how you try it before
    # turning it on.
    ch=$(jq -c '.enabled = true' <<<"$ch")
    step "Sending test alert to '${id}'..."
    _ALERT_LAST_FAIL=""
    _alert_deliver_channel "$ch" "$subject" "$body" ""
    if [[ -n "${_ALERT_LAST_FAIL}" ]]; then
        error "Test to '${id}' failed — the service refused the request or did not answer in time"
        exit 1
    fi
    success "Test sent to '${id}' — check the channel"
}

alerts_channel_command() {
    local sub="${1:-list}"; shift || true
    case "$sub" in
        add)            _alerts_add "$@" ;;
        update|edit)    _alerts_update "$@" ;;
        remove|rm)      _alerts_remove "$@" ;;
        list|ls|"")     _alerts_list "$@" ;;
        test)           _alerts_test "${1:-}" ;;
        enable)         [[ -n "${1:-}" ]] && _alerts_set_enabled "$1" true  || { error "Usage: cipi notification enable <id>"; exit 1; } ;;
        disable)        [[ -n "${1:-}" ]] && _alerts_set_enabled "$1" false || { error "Usage: cipi notification disable <id>"; exit 1; } ;;
        *)
            error "Use: add <type> <id> … | remove|list|test|enable|disable <id>  (types: smtp $(_alert_types); cipi help notification)"
            exit 1
            ;;
    esac
}
