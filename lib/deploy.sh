#!/bin/bash
#############################################
# Cipi — Deploy Management (Deployer)
#############################################

# Refuse to invoke `dep` for an app pinned to PHP < 8.3 when Deployer 8+ is
# installed: `dep` runs under the app's PHP, and the v8 phar can't even start
# on PHP < 8.3, so this fails fast with a clear message instead of a cryptic
# parse/version error. No-op under Deployer 7 (which supports older PHP).
_deploy_assert_php_compat() {
    local app="$1" php_ver="$2"
    [[ -z "$php_ver" ]] && return 0
    local dep_major; dep_major=$(deployer_major_version 2>/dev/null || echo "")
    [[ -z "$dep_major" ]] && return 0
    if (( dep_major >= 8 )) && ! validate_php_version "$php_ver"; then
        error "App '${app}' uses PHP ${php_ver}, but Deployer ${dep_major} requires PHP >= 8.3."
        warn  "Upgrade the app first:  cipi app edit ${app}   (set PHP to 8.3, 8.4 or 8.5)"
        warn  "Install the version if needed:  cipi php install 8.3"
        log_action "DEPLOY BLOCKED: $app php=${php_ver} dep=${dep_major}"
        exit 1
    fi
}

# ── Deploy log framing ───────────────────────────────────────
# /home/<app>/logs/deploy.log is written by both paths: `cipi deploy` (root)
# and the per-minute webhook trigger cron (cipi-app-deploy, app user). Raw
# Deployer output carries no dates and no release markers, so a deploy that
# failed overnight was unreadable after the fact. Every line gets a wall-clock
# timestamp, and each run is bracketed by a start/end banner naming the
# trigger, the branch, the release and the duration.

# Defensive on the argument: called from several places now, and under
# `set -u` a missing one would kill the whole process with an opaque
# "$1: unbound variable" instead of failing where the mistake is.
deploy_app_home() { echo "/home/${1:-}"; }
deploy_log_file() { echo "$(deploy_app_home "${1:-}")/logs/deploy.log"; }

# Release directory the `current` symlink points at ("54"), empty before the
# first successful deploy or for custom apps (no releases/).
deploy_current_release() {
    local app="${1:-}" target home
    [[ -n "$app" ]] || { echo ""; return 0; }
    home=$(deploy_app_home "$app")
    [[ -L "${home}/current" ]] || { echo ""; return 0; }
    target=$(readlink "${home}/current" 2>/dev/null || true)
    [[ -z "$target" ]] && { echo ""; return 0; }
    basename "$target"
}

# Copy stdin to stdout unchanged, and to $1 with a timestamp per line.
# printf's %(...)T is a bash builtin — no `date` subprocess per output line.
deploy_log_tee() {
    local lf="$1" line
    while IFS= read -r line; do
        printf '%s\n' "$line"
        printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$line" >> "$lf" 2>/dev/null || true
    done
}

deploy_log_open() {
    local app="$1" trigger="$2" branch="$3" from="$4" lf
    lf=$(deploy_log_file "$app")
    mkdir -p "$(dirname "$lf")" 2>/dev/null || true
    touch "$lf" 2>/dev/null || true
    printf '[%(%Y-%m-%d %H:%M:%S)T] ===== deploy start  app=%s trigger=%s branch=%s from-release=%s =====\n' \
        -1 "$app" "$trigger" "${branch:-?}" "${from:-none}" >> "$lf" 2>/dev/null || true
}

deploy_log_close() {
    local app="$1" result="$2" release="$3" secs="$4" rc="$5" lf
    lf=$(deploy_log_file "$app")
    printf '[%(%Y-%m-%d %H:%M:%S)T] ===== deploy %s  app=%s release=%s duration=%ss exit=%s =====\n\n' \
        -1 "$result" "$app" "${release:-?}" "$secs" "$rc" >> "$lf" 2>/dev/null || true
    # Root just appended to a log the app user owns — keep it writable for the
    # cron/webhook path, which runs as the app user.
    chown "${app}:www-data" "$lf" 2>/dev/null || true
    chmod 664 "$lf" 2>/dev/null || true
}

deploy_command() {
    local app="${1:-}"; shift||true
    [[ -z "$app" ]] && { error "Usage: cipi deploy <app> [--rollback|--releases|--log|--key|--webhook|--snapshot|--snapshot-required|--rollback-on-unhealthy]"; exit 1; }
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    parse_args "$@"

    if   [[ "${ARG_rollback:-}" == "true" ]];        then _deploy_rollback "$app"
    elif [[ -n "${ARG_log:-}" ]];                    then _deploy_log_show "$app" "${ARG_log}"
    elif [[ "${ARG_releases:-}" == "true" ]];        then _deploy_releases "$app"
    elif [[ "${ARG_key:-}" == "true" ]];             then _deploy_key "$app"
    elif [[ "${ARG_webhook:-}" == "true" ]];         then _deploy_webhook "$app"
    elif [[ "${ARG_unlock:-}" == "true" ]];          then _deploy_unlock "$app"
    elif [[ -n "${ARG_trust_host:-}" ]];             then _deploy_trust_host "$app" "${ARG_trust_host}"
    else _deploy_run "$app"
    fi
}

# Pre-deploy DB snapshot (root/vault only). Opt-in via apps.json or --snapshot.
_deploy_predeploy_snapshot() {
    local app="$1"
    local want="${ARG_snapshot:-}"
    local required="${ARG_snapshot_required:-}"
    [[ "$(app_get "$app" predeploy_snapshot)" == "true" ]] && want="true"
    [[ "$want" != "true" && "$required" != "true" ]] && return 0
    [[ "$(app_get "$app" custom)" == "true" ]] && return 0

    # shellcheck source=/dev/null
    source "${CIPI_LIB}/db.sh"
    local eng
    eng=$(app_get "$app" engine); [[ -z "$eng" ]] && eng="mariadb"
    eng=$(db_normalize_engine "$eng" 2>/dev/null || echo "mariadb")
    if ! db_engine_is_installed "$eng"; then
        warn "Pre-deploy snapshot skipped — engine ${eng} not installed"
        [[ "$required" == "true" ]] && { error "Snapshot required but engine missing"; return 1; }
        return 0
    fi

    mkdir -p "${CIPI_LOG}/backups"
    local dump="${CIPI_LOG}/backups/${eng}_${app}_predeploy_$(date +%Y%m%d_%H%M%S).sql.gz"
    step "Pre-deploy DB snapshot → ${dump}..."
    if db_dump_database "$eng" "$app" "$dump"; then
        success "Snapshot saved: ${dump}"
        echo "$dump" > "/tmp/cipi-predeploy-${app}.path" 2>/dev/null || true
        return 0
    fi

    cipi_notify \
        "Cipi pre-deploy snapshot failed: ${app} on $(hostname)" \
        "Database dump before deploy failed.\n\nServer: $(hostname)\nApp: ${app}\nEngine: ${eng}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        deploy_snapshot_fail
    if [[ "$required" == "true" ]]; then
        error "Pre-deploy snapshot failed (required)"
        return 1
    fi
    warn "Pre-deploy snapshot failed — continuing deploy"
    return 0
}

_deploy_run() {
    local app="$1"
    local home="/home/${app}"
    local df="${home}/.deployer/deploy.php"
    local php_ver; php_ver=$(app_get "$app" php)

    if [[ ! -f "$df" ]]; then
        step "Creating deployer config..."
        source "${CIPI_LIB}/app.sh"
        local repo branch is_custom
        repo=$(app_get "$app" repository)
        branch=$(app_get "$app" branch)
        is_custom=$(app_get "$app" custom)
        [[ -z "$php_ver" ]] && { error "App config incomplete (php). Run: cipi app edit $app"; exit 1; }
        if [[ "$is_custom" != "true" && -z "$repo" ]]; then
            error "App config incomplete (repository). Run: cipi app edit $app"
            exit 1
        fi
        _create_deployer_config_for_app "$app"
        success "Deployer config created"
    fi

    _deploy_assert_php_compat "$app" "$php_ver"

    # Legacy per-file ACLs on laravel-*.log break deploy:writable chmod — strip before Deployer runs.
    ensure_app_logs_permissions "$app" || true

    _deploy_predeploy_snapshot "$app" || exit 1
    local snapshot_path=""
    [[ -f "/tmp/cipi-predeploy-${app}.path" ]] && snapshot_path=$(cat "/tmp/cipi-predeploy-${app}.path" 2>/dev/null || true)

    local lf; lf=$(deploy_log_file "$app")
    local branch_disp; branch_disp=$(app_get "$app" branch)
    local rel_before; rel_before=$(deploy_current_release "$app")
    local t0=$SECONDS

    deploy_log_open "$app" "cli" "$branch_disp" "$rel_before"

    info "Deploying '${app}'..."
    echo ""

    # `set -e` would abort the whole `cipi` process the moment Deployer exits
    # non-zero — the failure branch below (and its deploy_fail notification)
    # was unreachable. Disable it around the run and read the real status from
    # PIPESTATUS[0]; the pipe adds a wall-clock timestamp to every logged line.
    local rc=0 had_e=0
    [[ $- == *e* ]] && had_e=1
    set +e
    sudo -u "$app" bash -c "cd ${home} && /usr/bin/php${php_ver} /usr/local/bin/dep deploy -f ${df} 2>&1" \
        | deploy_log_tee "$lf"
    rc=${PIPESTATUS[0]}
    [[ $had_e -eq 1 ]] && set -e

    local rel_after; rel_after=$(deploy_current_release "$app")
    local secs=$(( SECONDS - t0 ))
    echo ""

    if [[ $rc -eq 0 ]]; then
        deploy_log_close "$app" "OK" "$rel_after" "$secs" "$rc"
        success "Deploy completed${rel_after:+  (release ${rel_after}, ${secs}s)}"
        log_action "DEPLOY OK: $app release=${rel_after:-?} in ${secs}s"
        # The success notification is sent after the release has been verified,
        # so it can state whether the app actually answers — reporting "deploy
        # succeeded" while the site returns 500 would be worse than silence.
        _deploy_apply_yml "$app"
        local post_line post_rc=0
        post_line=$(_deploy_run_post_deploy "$app") || post_rc=$?
        local health_line; health_line=$(_deploy_health_check "$app")
        if [[ -x /usr/local/bin/cipi-scan-manifest ]]; then
            /usr/local/bin/cipi-scan-manifest "$app" >/dev/null 2>&1 || true
        fi
        [[ $post_rc -ne 0 ]] && warn "Post-deploy steps failed — see the deploy log."
        cipi_notify \
            "Cipi deploy succeeded: ${app} release ${rel_after:-?} on $(hostname)" \
            "Deploy completed successfully.\n\n$(_deploy_release_details "$app" "$rel_after" "$branch_disp" "$secs")Previous release: ${rel_before:-none}\nPost-deploy: ${post_line}\nHealthcheck: ${health_line}\n" \
            deploy_success
        [[ $post_rc -ne 0 ]] && return "$post_rc"
    else
        deploy_log_close "$app" "FAILED" "$rel_after" "$secs" "$rc"
        error "Deploy failed (exit $rc)"
        warn "Log: ${lf}"
        warn "Rollback code: cipi deploy ${app} --rollback"
        if [[ -n "$snapshot_path" && -f "$snapshot_path" ]]; then
            warn "DB snapshot (not restored automatically): ${snapshot_path}"
            warn "Restore: cipi db restore ${app} ${snapshot_path}"
        fi
        log_action "DEPLOY FAIL: $app exit=$rc release=${rel_after:-?}"
        cipi_notify \
            "Cipi deploy FAILED: ${app} on $(hostname)" \
            "Deploy exited with code ${rc}. Nothing was published — the previous release is still serving.\n\n$(_deploy_release_details "$app" "$rel_after" "$branch_disp" "$secs")Release still live: ${rel_after:-?}\n\nLast lines of the deploy log:\n$(tail -n 30 "$lf" 2>/dev/null || echo '<log unreadable>')\n\nRoll back further: cipi deploy ${app} --rollback" \
            deploy_fail
        return "$rc"
    fi
}

# ── Release detail for notifications ─────────────────────────
#
# "Deploy succeeded" on its own tells you nothing you can act on. What was
# actually published — which commit, by whom, on which release — is the part
# worth reading, and the part you need when deciding whether to roll back.

# "<sha>|<subject>|<author>|<date>" for a release, empty when it is not a git
# checkout (custom apps deployed by other means).
_deploy_commit_info() {
    local app="$1" release="$2" home dir
    home=$(deploy_app_home "$app")
    dir="${home}/releases/${release}"
    [[ -n "$release" ]] || return 0
    [[ -d "${dir}/.git" ]] || dir="${home}/current"
    [[ -d "${dir}/.git" ]] || return 0
    git -C "$dir" log -1 --format='%h|%s|%an|%ad' --date=format:'%Y-%m-%d %H:%M' 2>/dev/null || true
}

# Multi-line body shared by the success and failure notifications.
_deploy_release_details() {
    local app="$1" release="$2" branch="$3" secs="$4"
    local info sha subject author cdate
    info=$(_deploy_commit_info "$app" "$release")
    sha=""; subject=""; author=""; cdate=""
    if [[ -n "$info" ]]; then
        IFS='|' read -r sha subject author cdate <<< "$info"
    fi
    printf 'Server: %s\n' "$(hostname)"
    printf 'App: %s\n' "$app"
    printf 'Branch: %s\n' "${branch:-?}"
    printf 'Release: %s\n' "${release:-?}"
    [[ -n "$sha" ]]     && printf 'Commit: %s — %s\n' "$sha" "$subject"
    [[ -n "$author" ]]  && printf 'Author: %s\n' "$author"
    [[ -n "$cdate" ]]   && printf 'Committed: %s\n' "$cdate"
    printf 'Duration: %ss\n' "$secs"
    printf 'Time: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf 'Deploy log: %s\n' "$(deploy_log_file "$app")"
}

# ── Post-release verification and recovery ───────────────────
#
# Called after a release goes live, by both deploy paths. Probes the app and,
# when the app opted into it, rolls the release back if it does not answer.
#
# Auto-rollback moves the `current` symlink back to the previous release. It
# does NOT undo database migrations — a release that migrated the schema and
# then failed its healthcheck may well be worse off after a rollback, which is
# exactly why this is opt-in per app and never the default.
deploy_post_release_verify() {
    local app="$1" context="${2:-deploy}"
    declare -f health_post_deploy >/dev/null 2>&1 || source "${CIPI_LIB}/health.sh"

    local want_rollback=false
    [[ "$(app_get "$app" health_rollback)" == "true" ]] && want_rollback=true
    [[ "${ARG_rollback_on_unhealthy:-}" == "true" ]] && want_rollback=true
    [[ "${ARG_no_rollback_on_unhealthy:-}" == "true" ]] && want_rollback=false

    # When a rollback may follow, suppress the probe's own alert: the message
    # sent below describes the failure and the recovery together.
    DEPLOY_VERIFY_SUMMARY=""
    local rc=0
    health_post_deploy "$app" "$context" "$([[ "$want_rollback" == true ]] && echo false || echo true)" || rc=$?

    if [[ $rc -eq 2 ]]; then
        DEPLOY_VERIFY_SUMMARY="not configured (cipi health set ${app})"
        return 2
    fi
    if [[ $rc -eq 0 ]]; then
        DEPLOY_VERIFY_SUMMARY="passed — HTTP ${HEALTH_PD_LAST_CODE:-?}"
        return 0
    fi

    if [[ "$want_rollback" != true ]]; then
        DEPLOY_VERIFY_SUMMARY="FAILED — got ${HEALTH_PD_LAST_CODE:-?}, expected ${HEALTH_PD_LAST_EXPECT:-?} (a separate alert has been sent)"
        return 1
    fi

    _deploy_auto_rollback "$app" "$context"
    return 1
}

_deploy_auto_rollback() {
    local app="$1" context="$2" home
    home=$(deploy_app_home "$app")
    local bad_release; bad_release=$(deploy_current_release "$app")
    local branch; branch=$(app_get "$app" branch)
    local bad_code="${HEALTH_PD_LAST_CODE:-?}" url="${HEALTH_PD_LAST_URL:-?}" expect="${HEALTH_PD_LAST_EXPECT:-?}"
    local lf; lf=$(deploy_log_file "$app")

    local n=0
    [[ -d "${home}/releases" ]] && n=$(find "${home}/releases" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${n:-0}" -lt 2 ]]; then
        error "Auto-rollback requested but there is no previous release to return to."
        DEPLOY_VERIFY_SUMMARY="FAILED — HTTP ${bad_code}, and there is no earlier release to roll back to"
        cipi_notify \
            "Cipi deploy unhealthy: ${app} on $(hostname) — no rollback possible" \
            "The release that just went live is not answering, and there is no earlier release to roll back to.\n\n$(_deploy_release_details "$app" "$bad_release" "$branch" 0)\nHealthcheck: ${url}\nExpected: ${expect}\nGot: ${bad_code}\n\nThe release is live and serving this response. Manual intervention is needed." \
            deploy_health_fail
        return 1
    fi

    warn "Release ${bad_release:-?} is unhealthy — rolling back automatically."
    warn "Database migrations are NOT undone by this."
    printf '[%(%Y-%m-%d %H:%M:%S)T] ===== auto-rollback (unhealthy release %s) =====\n' -1 "${bad_release:-?}" \
        >> "$lf" 2>/dev/null || true

    local php_ver; php_ver=$(app_get "$app" php)
    local rrc=0 had_e=0
    [[ $- == *e* ]] && had_e=1
    set +e
    sudo -u "$app" bash -c "cd ${home} && /usr/bin/php${php_ver} /usr/local/bin/dep rollback -f ${home}/.deployer/deploy.php 2>&1" \
        | deploy_log_tee "$lf"
    rrc=${PIPESTATUS[0]}
    [[ $had_e -eq 1 ]] && set -e

    local now_release; now_release=$(deploy_current_release "$app")

    if [[ $rrc -ne 0 ]]; then
        error "Auto-rollback FAILED (exit ${rrc}) — the unhealthy release is still live."
        DEPLOY_VERIFY_SUMMARY="FAILED — HTTP ${bad_code}, and the automatic rollback also failed (release ${bad_release:-?} is still live)"
        log_action "AUTO-ROLLBACK FAIL: ${app} release=${bad_release:-?} exit=${rrc}"
        cipi_notify \
            "Cipi deploy unhealthy: ${app} — AUTOMATIC ROLLBACK FAILED on $(hostname)" \
            "The release that just went live failed its healthcheck, and the automatic rollback also failed.\n\n$(_deploy_release_details "$app" "$bad_release" "$branch" 0)\nHealthcheck: ${url}\nExpected: ${expect}\nGot: ${bad_code}\nRollback exit code: ${rrc}\n\nThe unhealthy release ${bad_release:-?} is STILL LIVE. Manual intervention is needed:\n  cipi deploy ${app} --rollback\n  cipi deploy ${app} --log" \
            deploy_health_fail
        return 1
    fi

    # Did returning to the previous release actually fix it?
    local hrc=0
    health_post_deploy "$app" "rollback" false || hrc=$?
    local after_code="${HEALTH_PD_LAST_CODE:-?}"

    log_action "AUTO-ROLLBACK: ${app} ${bad_release:-?} → ${now_release:-?} healthy=$([[ $hrc -eq 0 ]] && echo yes || echo no)"
    printf '[%(%Y-%m-%d %H:%M:%S)T] ===== auto-rollback done: %s -> %s (healthy=%s) =====\n\n' \
        -1 "${bad_release:-?}" "${now_release:-?}" "$([[ $hrc -eq 0 ]] && echo yes || echo no)" \
        >> "$lf" 2>/dev/null || true

    if [[ $hrc -eq 0 ]]; then
        DEPLOY_VERIFY_SUMMARY="FAILED — HTTP ${bad_code}; rolled back ${bad_release:-?} → ${now_release:-?}, healthy again"
        success "Rolled back to release ${now_release:-?} — the app is answering again."
        cipi_notify \
            "Cipi deploy rolled back: ${app} is healthy again on $(hostname)" \
            "The release that was just deployed did not answer, so it was rolled back automatically. The app is serving correctly again.\n\n$(_deploy_release_details "$app" "$bad_release" "$branch" 0)\nHealthcheck: ${url}\nExpected: ${expect}\nGot from the new release: ${bad_code}\n\nRolled back: ${bad_release:-?} → ${now_release:-?}\nStatus after rollback: ${after_code} (healthy)\n\nDatabase migrations from the failed release were NOT undone — check them.\nDeploy log: ${lf}" \
            deploy_health_fail
        return 1
    fi

    DEPLOY_VERIFY_SUMMARY="FAILED — HTTP ${bad_code}; rolled back ${bad_release:-?} → ${now_release:-?}, still unhealthy (${after_code})"
    error "Rolled back to release ${now_release:-?}, but the app is still not answering (${after_code})."
    cipi_notify \
        "Cipi deploy rolled back: ${app} is STILL unhealthy on $(hostname)" \
        "The release that was just deployed did not answer and was rolled back automatically — but the previous release is not answering either, so the cause is probably not the code.\n\n$(_deploy_release_details "$app" "$bad_release" "$branch" 0)\nHealthcheck: ${url}\nExpected: ${expect}\nGot from the new release: ${bad_code}\n\nRolled back: ${bad_release:-?} → ${now_release:-?}\nStatus after rollback: ${after_code} (still failing)\n\nLook at the database, queue workers, PHP-FPM and nginx before the code.\nDeploy log: ${lf}" \
        deploy_health_fail
    return 1
}

# Reconcile the server with the cipi.yml shipped in the release that was just
# put live — only for apps root opted in with `cipi yml auto <app> on`.
#
# The webhook path (cipi-app-deploy) does the same thing, and both must behave
# identically: a deploy that reads cipi.yml when triggered by a push but
# ignores it when triggered by hand would be worse than not reading it at all.
#
# A failure here never turns a successful deploy into a failed one — the code is
# live either way — but it is logged and `cipi yml apply` reports it by email.
_deploy_run_post_deploy() {
    local app="$1"
    # shellcheck source=/dev/null
    declare -f _yml_post_deploy_run >/dev/null 2>&1 || source "${CIPI_LIB}/yml.sh"
    local php_ver lf summary rc=0
    php_ver=$(app_get "$app" php)
    [[ -n "$php_ver" ]] || { echo "skipped (no php version)"; return 0; }
    lf=$(deploy_log_file "$app")
    echo ""
    step "Post-deploy steps (cipi.yml)..."
    set +e
    summary=$(_yml_post_deploy_run "$app" "$php_ver" "$lf" false root)
    rc=$?
    set -e
    chown "${app}:www-data" "$lf" 2>/dev/null || true
    printf '%s' "$summary"
    return "$rc"
}

_deploy_apply_yml() {
    local app="$1"
    [[ "$(app_get "$app" yml_auto)" == "true" ]] || return 0

    local lf; lf=$(deploy_log_file "$app")
    echo ""
    step "Applying cipi.yml..."
    printf '[%(%Y-%m-%d %H:%M:%S)T] ===== cipi.yml apply =====\n' -1 >> "$lf" 2>/dev/null || true

    local rc=0 had_e=0
    [[ $- == *e* ]] && had_e=1
    set +e
    ( source "${CIPI_LIB}/yml.sh"; yml_command apply "$app" --yes --auto ) 2>&1 | deploy_log_tee "$lf"
    rc=${PIPESTATUS[0]}
    [[ $had_e -eq 1 ]] && set -e

    if [[ $rc -ne 0 ]]; then
        warn "cipi.yml was not applied — the deploy itself succeeded."
        warn "Details: ${lf}   Retry: cipi yml apply ${app}"
    fi
    chown "${app}:www-data" "$lf" 2>/dev/null || true
    return 0
}

# Verify the release that just went live actually answers, and say so in the
# deploy log. A deploy reports that the code was published; this reports
# whether the site survived it — the two are not the same thing, and until now
# a deploy that returned 500 on every page still looked like a success.
#
# The verdict deliberately does not change the deploy's exit code: the release
# *is* live either way, and rolling back is a decision for whoever reads the
# alert. `cipi deploy <app> --rollback` is one command away.
# Runs the verification (and any opted-in recovery), streams its output to the
# terminal and the deploy log, and prints a one-line verdict on stdout for the
# success notification to quote.
_deploy_health_check() {
    local app="$1"
    local lf; lf=$(deploy_log_file "$app")

    declare -f deploy_post_release_verify >/dev/null 2>&1 || source "${CIPI_LIB}/health.sh"

    local rc=0 had_e=0
    [[ $- == *e* ]] && had_e=1
    set +e
    deploy_post_release_verify "$app" "deploy" 2>&1 | deploy_log_tee "$lf" >&2
    rc=${PIPESTATUS[0]}
    [[ $had_e -eq 1 ]] && set -e

    if [[ $rc -eq 2 && -t 2 ]]; then
        # Worth one quiet line for someone watching a deploy by hand; never in a
        # webhook log, where it would repeat forever.
        echo -e "  ${DIM}No healthcheck for '${app}' — set one: cipi health set ${app}${NC}" >&2
    fi
    [[ $rc -eq 1 ]] && warn "Deploy succeeded but the app is not answering as expected."

    chown "${app}:www-data" "$lf" 2>/dev/null || true
    echo "${DEPLOY_VERIFY_SUMMARY:-unknown}"
    return 0
}

# cipi deploy <app> --log        → last 200 lines
# cipi deploy <app> --log=500    → last 500 lines
_deploy_log_show() {
    local app="$1" want="$2" lines=200 lf
    [[ "$want" =~ ^[0-9]+$ ]] && lines="$want"
    lf=$(deploy_log_file "$app")
    [[ -f "$lf" ]] || { info "No deploy log yet for '${app}' (${lf})"; return 0; }
    echo -e "\n${BOLD}Deploy log — ${app}${NC} ${DIM}(last ${lines} lines of ${lf})${NC}\n"
    tail -n "$lines" "$lf"
    echo ""
}

_deploy_unlock() {
    local app="$1"
    local home="/home/${app}"
    local lockfile="${home}/.dep/deploy.lock"
    if [[ ! -f "$lockfile" ]]; then
        info "No deploy lock found for '${app}'"
        return 0
    fi
    rm -f "$lockfile"
    success "Deploy unlocked — run: cipi deploy ${app}"
    log_action "DEPLOY UNLOCK: $app"
}

_deploy_rollback() {
    local app="$1"
    local home="/home/${app}"
    local php_ver; php_ver=$(app_get "$app" php)
    _deploy_assert_php_compat "$app" "$php_ver"
    # Skip confirmation for non-interactive callers (API/UI job runner): a
    # blocking `read` with no TTY would hang the job. --force is parsed upstream
    # in deploy_command.
    if [[ "${ARG_force:-}" != "true" ]] && [[ -t 0 ]]; then
        confirm "Rollback '${app}'?" || { info "Cancelled"; return; }
    fi
    local lf; lf=$(deploy_log_file "$app")
    local rel_before; rel_before=$(deploy_current_release "$app")
    local t0=$SECONDS
    deploy_log_open "$app" "rollback" "$(app_get "$app" branch)" "$rel_before"

    info "Rolling back..."
    # Same `set -e` trap as _deploy_run: an unguarded sudo would abort cipi
    # before the failure branch and before the notification.
    local rc=0 had_e=0
    [[ $- == *e* ]] && had_e=1
    set +e
    sudo -u "$app" bash -c "cd ${home} && /usr/bin/php${php_ver} /usr/local/bin/dep rollback -f ${home}/.deployer/deploy.php 2>&1" \
        | deploy_log_tee "$lf"
    rc=${PIPESTATUS[0]}
    [[ $had_e -eq 1 ]] && set -e

    local rel_after; rel_after=$(deploy_current_release "$app")
    local secs=$(( SECONDS - t0 ))
    if [[ $rc -eq 0 ]]; then
        deploy_log_close "$app" "ROLLBACK OK" "$rel_after" "$secs" "$rc"
        # `current` now points at an older tree, so the manifest from the newer
        # release would read as integrity drift every night until the next
        # deploy — training the operator to ignore the one alert that means
        # "webshell".
        if [[ -x /usr/local/bin/cipi-scan-manifest ]]; then
            /usr/local/bin/cipi-scan-manifest "$app" >/dev/null 2>&1 || true
        fi
        success "Rollback done${rel_after:+  (now on release ${rel_after})}"
        log_action "ROLLBACK OK: $app ${rel_before:-?} → ${rel_after:-?}"
        cipi_notify \
            "Cipi deploy rollback: ${app} on $(hostname)" \
            "Deploy rollback completed.\n\nServer: $(hostname)\nApp: ${app}\nRelease: ${rel_before:-?} → ${rel_after:-?}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
            deploy_rollback
    else
        deploy_log_close "$app" "ROLLBACK FAILED" "$rel_after" "$secs" "$rc"
        error "Rollback failed (exit $rc)"
        warn "Log: ${lf}"
        log_action "ROLLBACK FAIL: $app exit=$rc"
        cipi_notify \
            "Cipi deploy rollback failed: ${app} on $(hostname)" \
            "Rollback exited with code ${rc}.\n\nServer: $(hostname)\nApp: ${app}\nRelease still live: ${rel_after:-?}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')\n\nLast lines of ${lf}:\n$(tail -n 30 "$lf" 2>/dev/null || echo '<log unreadable>')" \
            deploy_fail
        return "$rc"
    fi
}

# Release directories stay numeric (Deployer increments them, and rollback
# relies on that ordering). The date and the deployed commit are shown here
# instead, which is what the numbers alone failed to tell you.
_deploy_releases() {
    local app="$1"
    local home="/home/${app}"
    [[ ! -d "${home}/releases" ]] && { info "No releases yet"; return; }
    local current=""
    [[ -L "${home}/current" ]] && current=$(readlink -f "${home}/current" | xargs basename)

    echo -e "\n${BOLD}Releases for '${app}'${NC}"
    printf "  ${BOLD}%-8s %-20s %-10s %s${NC}\n" "RELEASE" "DEPLOYED" "COMMIT" "SUBJECT"
    local r when sha subject mark
    while read -r r; do
        [[ -n "$r" ]] || continue
        when=$(stat -c '%y' "${home}/releases/${r}" 2>/dev/null | cut -d. -f1)
        sha=""; subject=""
        if [[ -d "${home}/releases/${r}/.git" ]]; then
            sha=$(git -C "${home}/releases/${r}" log -1 --format=%h 2>/dev/null || true)
            subject=$(git -C "${home}/releases/${r}" log -1 --format=%s 2>/dev/null | cut -c1-46 || true)
        fi
        mark=""; [[ "$r" == "$current" ]] && mark=" ${GREEN}← current${NC}"
        printf "  ${CYAN}%-8s${NC} %-20s %-10s %s%b\n" "$r" "${when:-—}" "${sha:-—}" "${subject:-—}" "$mark"
    done < <(ls -1t "${home}/releases" 2>/dev/null)
    echo ""
    echo -e "  ${DIM}Rollback to the previous release: cipi deploy ${app} --rollback${NC}"
    echo -e "  ${DIM}Deploy log (timestamped): $(deploy_log_file "$app")${NC}"
    echo ""
}

_deploy_key() {
    local app="$1"
    local kf="/home/${app}/.ssh/id_ed25519.pub"
    [[ ! -f "$kf" ]] && { error "Key not found"; exit 1; }
    echo -e "\n${BOLD}Deploy Key for '${app}'${NC}"
    echo -e "${CYAN}$(cat "$kf")${NC}\n"

    local git_prov; git_prov=$(app_get "$app" git_provider)
    local git_dkid; git_dkid=$(app_get "$app" git_deploy_key_id)
    if [[ -n "$git_prov" && -n "$git_dkid" ]]; then
        echo -e "  ${GREEN}✓ Auto-configured on ${git_prov} (ID: ${git_dkid})${NC}"
    else
        echo "Add as Deploy Key in your Git provider:"
        echo "  GitHub:      Repo → Settings → Deploy keys → Add deploy key"
        echo "  GitLab:      Repo → Settings → Repository → Deploy keys"
        echo "  Origin:      origin ssh-key add ~/.ssh/id_ed25519.pub  (account SSH key)"
        echo "  Bitbucket:   Repo → Repository settings → Access keys"
        echo "  Azure:       User settings → SSH public keys"
        echo "  CodeCommit:  IAM → user → Security credentials → Upload SSH public key"
        echo "  Gitea:       Repo → Settings → Deploy keys → Add key"
        echo "  Forgejo:     Repo → Settings → Deploy keys → Add key"
        echo "  Custom:      append to ~/.ssh/authorized_keys on the git server"
    fi
    echo ""
    echo "  Trust the host fingerprint with:"
    echo "  ${CYAN}cipi deploy ${app} --trust-host=<host[:port]>${NC}"
    echo ""
}

_deploy_trust_host() {
    local app="$1" hostport="$2"
    local home="/home/${app}" known_hosts

    # Split host and optional port
    local host port
    if [[ "$hostport" == *:* ]]; then
        host="${hostport%%:*}"
        port="${hostport##*:}"
    else
        host="$hostport"
        port="22"
    fi

    [[ -z "$host" ]] && { error "Usage: cipi deploy <app> --trust-host=<host[:port]>"; exit 1; }

    known_hosts="${home}/.ssh/known_hosts"

    step "Scanning SSH fingerprint of ${host}:${port}..."
    local scan_out
    if [[ "$port" == "22" ]]; then
        scan_out=$(ssh-keyscan -T 10 -H "$host" 2>/dev/null)
    else
        scan_out=$(ssh-keyscan -T 10 -p "$port" -H "$host" 2>/dev/null)
    fi

    if [[ -z "$scan_out" ]]; then
        error "Could not reach ${host}:${port} — check the hostname and that port ${port} is open"
        exit 1
    fi

    # Remove any existing entry for this host to avoid duplicates
    if [[ -f "$known_hosts" ]]; then
        local tmp; tmp=$(mktemp)
        ssh-keygen -R "$host" -f "$known_hosts" &>/dev/null || true
        [[ "$port" != "22" ]] && ssh-keygen -R "[${host}]:${port}" -f "$known_hosts" &>/dev/null || true
    fi

    echo "$scan_out" >> "$known_hosts"
    chown "${app}:${app}" "$known_hosts"
    chmod 600 "$known_hosts"

    success "Fingerprint of ${host}:${port} trusted for '${app}'"
    echo ""
    echo -e "${BOLD}Fingerprints added:${NC}"
    echo "$scan_out" | awk '{print "  " $0}' | cut -c1-80
    echo ""

    # Show the deploy key as a reminder
    local kf="${home}/.ssh/id_ed25519.pub"
    if [[ -f "$kf" ]]; then
        echo -e "${BOLD}Deploy Key${NC} (add this to your Git server):"
        echo -e "  ${CYAN}$(cat "$kf")${NC}"
        echo ""
    fi

    # If non-standard port, write/update SSH config entry
    if [[ "$port" != "22" ]]; then
        local ssh_cfg="${home}/.ssh/config"
        # Remove existing Host block for this host if any
        if [[ -f "$ssh_cfg" ]]; then
            local tmp; tmp=$(mktemp)
            awk -v h="$host" '
                /^Host / { in_block = ($2 == h) }
                !in_block { print }
            ' "$ssh_cfg" > "$tmp" && mv "$tmp" "$ssh_cfg"
        fi
        cat >> "$ssh_cfg" <<SSHCFG

Host ${host}
    HostName ${host}
    Port ${port}
    IdentityFile ${home}/.ssh/id_ed25519
    StrictHostKeyChecking accept-new
SSHCFG
        chown "${app}:${app}" "$ssh_cfg"
        chmod 600 "$ssh_cfg"
        success "SSH config updated (port ${port} → ${host})"
    fi

    log_action "TRUST HOST: $app → ${host}:${port}"
}

_deploy_webhook() {
    local app="$1"
    local d; d=$(app_get "$app" domain)
    local t; t=$(app_get "$app" webhook_token)
    echo -e "\n${BOLD}Webhook for '${app}'${NC}"
    echo -e "  URL:   ${CYAN}https://$(domain_url_host "$d")/cipi/webhook${NC}"
    echo -e "  Token: ${CYAN}${t}${NC}"
    echo ""

    local git_prov; git_prov=$(app_get "$app" git_provider)
    local git_whid; git_whid=$(app_get "$app" git_webhook_id)
    if [[ -n "$git_prov" && -n "$git_whid" ]]; then
        echo -e "  ${GREEN}✓ Auto-configured on ${git_prov} (ID: ${git_whid})${NC}"
    else
        echo "  GitHub: Repo → Settings → Webhooks → Add"
        echo "    Payload URL: https://$(domain_url_host "$d")/cipi/webhook"
        echo "    Secret: ${t}"
        echo "    Events: Push only"
        echo ""
        echo "  GitLab: Repo → Settings → Webhooks"
        echo "    URL: https://$(domain_url_host "$d")/cipi/webhook"
        echo "    Secret token: ${t}"
        echo ""
        echo "  Bitbucket: Repo → Repository settings → Webhooks"
        echo "    URL: https://$(domain_url_host "$d")/cipi/webhook"
        echo "    Secret: ${t}   Events: Repository push"
        echo ""
        echo "  Azure DevOps: Project → Service hooks → Web Hooks"
        echo "    URL: https://$(domain_url_host "$d")/cipi/webhook"
        echo "    Header: X-Gitlab-Token: ${t}   Event: Code pushed"
        echo ""
        echo "  Origin / CodeCommit: no per-repo HTTP webhook — run: cipi deploy ${app}"
    fi
    echo ""
    echo "  Requires: composer require cipi/agent"
    echo ""
}
