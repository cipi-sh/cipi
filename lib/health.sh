#!/bin/bash
#############################################
# Cipi — HTTP healthchecks + alerts
#############################################

# The time of a notification is common.sh's (and follows `cipi notification
# timezone`); loaded on its own, this file still has a clock.
declare -f notify_now >/dev/null 2>&1 || notify_now() { date "$@" '+%Y-%m-%d %H:%M:%S %Z'; }

[[ -z "${HEALTH_STATE_DIR:-}" ]] && readonly HEALTH_STATE_DIR="${CIPI_LOG}/health"
[[ -z "${HEALTH_CRON:-}" ]]      && readonly HEALTH_CRON="/etc/cron.d/cipi-health"
[[ -z "${HEALTH_HELPER:-}" ]]    && readonly HEALTH_HELPER="/usr/local/bin/cipi-health-check"

health_command() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        set)   _health_set "$@" ;;
        unset) _health_unset "$@" ;;
        check) _health_check_one "$@" ;;
        postdeploy) _health_postdeploy_cmd "$@" ;;
        list)  _health_list "$@" ;;
        *) error "Usage: cipi health set|unset|check|postdeploy|list <app> [--url=] [--expect=200] [--grace=N] [--json]"; exit 1 ;;
    esac
}

_health_ensure_cron() {
    mkdir -p "$HEALTH_STATE_DIR"
    if [[ ! -x "$HEALTH_HELPER" && -f "${CIPI_LIB}/cipi-health-check.sh" ]]; then
        if cp "${CIPI_LIB}/cipi-health-check.sh" "$HEALTH_HELPER" 2>/dev/null; then
            chmod 755 "$HEALTH_HELPER" 2>/dev/null || true
        else
            warn "Could not install ${HEALTH_HELPER} — the 5-minute check will not run"
            warn "(the post-deploy check still works)"
        fi
    fi
    if [[ ! -f "$HEALTH_CRON" ]]; then
        if cat > "$HEALTH_CRON" 2>/dev/null <<EOF
# Cipi app HTTP healthchecks (every 5 minutes)
*/5 * * * * root ${HEALTH_HELPER} >/dev/null 2>&1
EOF
        then
            chmod 644 "$HEALTH_CRON" 2>/dev/null || true
        else
            warn "Could not write ${HEALTH_CRON} — the 5-minute check will not run"
            warn "(the post-deploy check still works)"
        fi
    fi
}

_health_set() {
    local app="${1:-}"; shift || true
    [[ -z "$app" ]] && { error "Usage: cipi health set <app> [--url=https://domain/up] [--expect=200]"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    parse_args "$@"
    local url="${ARG_url:-}"
    local expect="${ARG_expect:-}"
    local grace="${ARG_grace:-}"
    # `cipi health set <app> --no-postdeploy` adjusts a check that exists: it
    # keeps the URL and the status already set instead of resetting them to the
    # defaults, which would silently re-aim a custom URL at /up.
    [[ -n "$url" ]]    || url=$(app_get "$app" health_url)
    [[ -n "$expect" ]] || expect=$(app_get "$app" health_expect)
    [[ -n "$expect" ]] || expect=200
    if [[ -z "$url" ]]; then
        local domain; domain=$(app_get "$app" domain)
        # A wildcard domain answers only on a concrete subdomain, and guessing
        # one here would arm a check (and a post-deploy rollback) against a host
        # that may not exist.
        if domain_is_wildcard "$domain"; then
            error "'${app}' is served on the wildcard domain '${domain}' — pass an explicit --url=https://<host>/up"
            exit 1
        fi
        url="https://${domain}/up"
    fi
    [[ "$expect" =~ ^[0-9]+$ ]] || { error "--expect must be an HTTP status code"; exit 1; }
    [[ "$url" =~ ^https?:// ]] || { error "--url must start with http:// or https://"; exit 1; }
    if [[ -n "$grace" ]]; then
        [[ "$grace" =~ ^[0-9]+$ && "$grace" -le 120 ]] \
            || { error "--grace must be a whole number of seconds, at most 120"; exit 1; }
    fi

    app_set "$app" health_url "$url"
    app_set "$app" health_expect "$expect"
    [[ -n "$grace" ]] && app_set "$app" health_grace "$grace"
    if [[ "${ARG_rollback_on_unhealthy:-}" == "true" ]]; then
        app_set "$app" health_rollback "true"
    elif [[ "${ARG_no_rollback_on_unhealthy:-}" == "true" ]]; then
        app_unset "$app" health_rollback
    fi
    if [[ "${ARG_no_postdeploy:-}" == "true" ]]; then
        app_set "$app" health_postdeploy "false"
    elif [[ "${ARG_postdeploy:-}" == "true" ]]; then
        app_unset "$app" health_postdeploy
    fi
    _health_ensure_cron
    log_action "HEALTH SET: $app url=$url expect=$expect"
    success "Healthcheck set for '${app}': ${url} (expect ${expect})"
    if [[ "$(app_get "$app" health_postdeploy)" == "false" ]]; then
        info "Checked every 5 minutes. Post-deploy verification is off for this app."
    else
        info "Checked every 5 minutes, and right after every deploy."
    fi
    info "History (status and response time every minute): cipi metrics uptime ${app}"
    if [[ "$(app_get "$app" health_rollback)" == "true" ]]; then
        warn "Auto-rollback is ON: an unhealthy release is rolled back automatically."
        warn "Database migrations are NOT undone — only the code symlink moves."
    fi
}

_health_unset() {
    local app="${1:-}"
    [[ -z "$app" ]] && { error "Usage: cipi health unset <app>"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    app_unset "$app" health_url
    app_unset "$app" health_expect
    app_unset "$app" health_grace
    app_unset "$app" health_postdeploy
    app_unset "$app" health_rollback
    rm -f "${HEALTH_STATE_DIR}/${app}.state" "${HEALTH_STATE_DIR}/${app}.failcount"
    log_action "HEALTH UNSET: $app"
    success "Healthcheck removed for '${app}'"
}

_health_check_one() {
    local app="${1:-}"; shift || true
    parse_args "$@"
    [[ -z "$app" ]] && { error "Usage: cipi health check <app> [--json]"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    local url expect
    url=$(app_get "$app" health_url)
    expect=$(app_get "$app" health_expect)
    [[ -z "$url" ]] && { error "No healthcheck configured. Run: cipi health set ${app}"; exit 1; }
    [[ -z "$expect" ]] && expect=200

    local code
    # curl already writes "000" through -w when the connection fails; a fallback
    # `|| echo 000` would append a second one and produce "000000".
    code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 -L "$url" 2>/dev/null) || true
    [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
    local ok=false
    [[ "$code" == "$expect" ]] && ok=true

    if [[ "${ARG_json:-}" == "true" ]]; then
        jq -n --arg app "$app" --arg url "$url" --argjson expect "$expect" --arg got "$code" --argjson ok "$ok" \
            '{app:$app,url:$url,expect:$expect,got:$got,ok:$ok}'
        [[ "$ok" == "true" ]] && return 0 || return 1
    fi

    if [[ "$ok" == "true" ]]; then
        success "OK ${code} ← ${url}"
        return 0
    fi
    error "FAIL got ${code}, expected ${expect} ← ${url}"
    return 1
}

_health_list() {
    parse_args "$@"
    local json
    json=$(vault_read apps.json)

    if [[ "${ARG_json:-}" == "true" ]]; then
        local items="[]"
        while IFS=$'\t' read -r app url expect; do
            [[ -z "$app" ]] && continue
            local state="" failcount=0
            [[ -f "${HEALTH_STATE_DIR}/${app}.state" ]] && state=$(cat "${HEALTH_STATE_DIR}/${app}.state" 2>/dev/null || true)
            [[ -f "${HEALTH_STATE_DIR}/${app}.failcount" ]] && failcount=$(cat "${HEALTH_STATE_DIR}/${app}.failcount" 2>/dev/null || echo 0)
            [[ "$failcount" =~ ^[0-9]+$ ]] || failcount=0
            items=$(echo "$items" | jq -c \
                --arg app "$app" --arg url "$url" --argjson expect "${expect:-200}" \
                --arg state "$state" --argjson fc "$failcount" \
                '. + [{app:$app,url:$url,expect:$expect,state:(if $state=="" then null else $state end),failcount:$fc}]')
        done < <(echo "$json" | jq -r 'to_entries[] | select(.value.health_url != null and .value.health_url != "") | "\(.key)\t\(.value.health_url)\t\(.value.health_expect // "200")"')
        jq -n --argjson checks "$items" '{checks:$checks}'
        return 0
    fi

    echo -e "\n${BOLD}Healthchecks${NC}"
    tbl_start
    local app url expect
    while IFS=$'\t' read -r app url expect; do
        [[ -n "$app" ]] || continue
        tbl_row "$app" "$url" "expect=${expect}"
    done < <(echo "$json" | jq -r 'to_entries[] | select(.value.health_url != null and .value.health_url != "") | "\(.key)\t\(.value.health_url)\t\(.value.health_expect // "200")"')
    tbl_print
    echo ""
}

# ── Post-deploy verification ─────────────────────────────────
#
# The periodic cron deliberately debounces: it only alerts after three
# consecutive failures (~15 minutes), because a single blip on a healthy site
# is noise. Right after a deploy the opposite is true — the interesting
# question is "did the release I just put live break the site?", and that
# answer must arrive immediately, not a quarter of an hour later.
#
# So this probes with short retries (the app needs a moment: FPM reload,
# opcache, an Octane restart) and reports the first settled verdict.
#
# Exit: 0 healthy, 1 unhealthy, 2 no healthcheck configured for this app.

[[ -z "${HEALTH_PD_ATTEMPTS:-}" ]] && readonly HEALTH_PD_ATTEMPTS=5
[[ -z "${HEALTH_PD_DELAY:-}" ]]    && readonly HEALTH_PD_DELAY=3

# Seconds to wait before the first probe. An Octane/Reverb app is restarted by
# supervisor as part of the deploy, so it needs longer than an FPM app whose
# pool is simply reloaded.
_health_grace_for() {
    local app="$1" grace
    grace=$(app_get "$app" health_grace 2>/dev/null || true)
    if [[ -n "$grace" && "$grace" =~ ^[0-9]+$ ]]; then echo "$grace"; return 0; fi
    if [[ -n "$(app_get "$app" octane 2>/dev/null || true)" ]]; then echo 8; else echo 3; fi
}

# health_post_deploy <app> [context] [notify]
#   notify=false suppresses the alert — used by the auto-rollback flow, which
#   sends one message describing the failure *and* what it did about it rather
#   than two describing halves of the same event.
health_post_deploy() {
    local app="$1" context="${2:-deploy}" notify="${3:-true}"
    local url expect grace

    url=$(app_get "$app" health_url 2>/dev/null || true)
    [[ -z "$url" ]] && return 2
    [[ "$(app_get "$app" health_postdeploy 2>/dev/null || true)" == "false" ]] && return 2
    [[ "$(app_get "$app" suspended 2>/dev/null || true)" == "true" ]] && return 2

    expect=$(app_get "$app" health_expect 2>/dev/null || true)
    [[ -z "$expect" ]] && expect=200
    grace=$(_health_grace_for "$app")

    step "Post-deploy healthcheck: ${url} (expect ${expect})"
    [[ "$grace" -gt 0 ]] && sleep "$grace"

    local attempt=1 code="000"
    while [[ $attempt -le $HEALTH_PD_ATTEMPTS ]]; do
        code=$(curl -sS -o /dev/null -w '%{http_code}' \
                    --connect-timeout 5 --max-time 15 -L "$url" 2>/dev/null) || true
        [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
        [[ "$code" == "$expect" ]] && break
        [[ $attempt -lt $HEALTH_PD_ATTEMPTS ]] && sleep "$HEALTH_PD_DELAY"
        ((attempt++)) || true
    done

    mkdir -p "$HEALTH_STATE_DIR" 2>/dev/null || true
    HEALTH_PD_LAST_CODE="$code"
    HEALTH_PD_LAST_URL="$url"
    HEALTH_PD_LAST_EXPECT="$expect"
    local release=""
    declare -f deploy_current_release >/dev/null 2>&1 && release=$(deploy_current_release "$app")

    if [[ "$code" == "$expect" ]]; then
        # Reset the periodic checker's counter too: the site is up now, and a
        # stale count from before the deploy must not fire later.
        echo "ok" > "${HEALTH_STATE_DIR}/${app}.state" 2>/dev/null || true
        echo "0"  > "${HEALTH_STATE_DIR}/${app}.failcount" 2>/dev/null || true
        success "Healthcheck passed — HTTP ${code}${release:+ (release ${release})}"
        log_action "HEALTH POSTDEPLOY OK: ${app} ${code} ${url}"
        return 0
    fi

    echo "fail:${code}" > "${HEALTH_STATE_DIR}/${app}.state" 2>/dev/null || true
    error "Healthcheck FAILED after ${HEALTH_PD_ATTEMPTS} attempts — got ${code}, expected ${expect}"
    error "  ${url}"
    warn  "The new release is live and serving this. Roll back with: cipi deploy ${app} --rollback"
    # A deploy that was never asked to verify anything is a surprise, and a 404
    # is usually the URL rather than the release: say where this check comes
    # from and how to change it, right where the verdict is read.
    if [[ "$code" == "404" ]]; then
        info "404 means the URL does not exist on the app — Laravel serves /up only with the health route on (bootstrap/app.php: health: '/up')."
    fi
    info "This check was set with 'cipi health set ${app}', the panel, or a cipi.yml 'health:' block."
    info "Change the URL: cipi health set ${app} --url=…   skip it after deploys: cipi health set ${app} --no-postdeploy   remove it: cipi health unset ${app}"
    log_action "HEALTH POSTDEPLOY FAIL: ${app} got=${code} want=${expect} ${url}"

    [[ "$notify" != "true" ]] && return 1
    local origin_hint="This check was set with 'cipi health set ${app}', the panel, or a cipi.yml 'health:' block."
    [[ "$code" == "404" ]] && origin_hint="404: the URL does not exist on the app — Laravel serves /up only with the health route on (bootstrap/app.php: health: '/up').\n${origin_hint}"
    cipi_notify \
        "Cipi post-deploy healthcheck failed: ${app} on $(hostname)" \
        "The application did not answer correctly after a ${context}.\n\nServer: $(hostname)\nApp: ${app}\nRelease now live: ${release:-?}\nURL: ${url}\nExpected: ${expect}\nGot: ${code}\nAttempts: ${HEALTH_PD_ATTEMPTS} over $(( grace + (HEALTH_PD_ATTEMPTS - 1) * HEALTH_PD_DELAY ))s\nTime: $(notify_now)\n\nThe release is live and serving this response.\nRoll back with:  cipi deploy ${app} --rollback\nDeploy log:      /home/${app}/logs/deploy.log\n\n${origin_hint}\nChange the URL:        cipi health set ${app} --url=…\nSkip it after deploys: cipi health set ${app} --no-postdeploy\nRemove it:             cipi health unset ${app}" \
        deploy_health_fail
    return 1
}

# `cipi health postdeploy <app>` is a plain probe — running it by hand must
# never move a live site. `--auto` is the post-deploy path (root, or the app
# user through one exact sudoers rule) and additionally applies whatever
# recovery the app has opted into.
_health_postdeploy_cmd() {
    local app="${1:-}"; shift || true
    [[ -z "$app" ]] && { error "Usage: cipi health postdeploy <app> [--auto]"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    parse_args "$@"

    if [[ "${ARG_auto:-}" == "true" ]]; then
        declare -f deploy_post_release_verify >/dev/null 2>&1 || source "${CIPI_LIB}/deploy.sh"
        deploy_post_release_verify "$app" "deploy"
        return $?
    fi

    local rc=0
    health_post_deploy "$app" "manual check" || rc=$?
    case $rc in
        0) return 0 ;;
        2) info "No post-deploy healthcheck configured for '${app}'"
           info "Set one with: cipi health set ${app}"
           return 0 ;;
        *) return 1 ;;
    esac
}
