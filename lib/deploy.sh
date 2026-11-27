#!/bin/bash
#############################################
# Cipi — Deploy Management (Deployer)
#############################################

# The time of a notification is common.sh's (and follows `cipi notification
# timezone`); loaded on its own, this file still has a clock.
declare -f notify_now >/dev/null 2>&1 || notify_now() { date "$@" '+%Y-%m-%d %H:%M:%S %Z'; }

# Refuse to invoke `dep` for an app pinned to PHP < 8.3 when Deployer 8+ is
# installed: `dep` runs under the app's PHP, and the v8 phar can't even start
# on PHP < 8.3, so this fails fast with a clear message instead of a cryptic
# parse/version error. No-op under Deployer 7 (which supports older PHP).
_deploy_assert_php_compat() {
    local app="$1" php_ver="$2"
    [[ -z "$php_ver" ]] && return 0
    local dep_major; dep_major=$(deployer_major_version 2>/dev/null || echo "")
    [[ -z "$dep_major" ]] && return 0
    # Deployer 6 (what deployer.org/deployer.phar serves, which setup.sh
    # downloaded up to 5.9.1) has no deploy:publish: every deploy would stop
    # at "Task `deploy:publish` not found" (#519).
    if (( dep_major < 7 )); then
        error "Deployer ${dep_major} is installed at /usr/local/bin/dep; Cipi's recipes need Deployer 8."
        warn  "Update Cipi (cipi self-update installs it), or by hand:"
        warn  "  source /opt/cipi/lib/deployer-install.sh && cipi_deployer_install"
        log_action "DEPLOY BLOCKED: $app dep=${dep_major}"
        exit 1
    fi
    if (( dep_major >= 8 )) && ! validate_php_version "$php_ver"; then
        error "App '${app}' uses PHP ${php_ver}, but Deployer ${dep_major} requires PHP >= 8.3."
        warn  "Upgrade the app first:  cipi app edit ${app}   (set PHP to 8.3, 8.4, 8.5 or 8.6)"
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
# The deploy log lives in root's /var/log/cipi-apps/<app> since 5.9.0
# (~/logs/deploy.log is a symlink to it): `cipi deploy` appends to it as root
# and used to chown it afterwards — in ~/logs, on whatever a symlink called
# deploy.log pointed at. See app_log_dir in common.sh.
deploy_log_file() { echo "/var/log/cipi-apps/${1:-}/deploy.log"; }

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
    if declare -f app_log_dir_ensure >/dev/null 2>&1; then
        app_log_dir_ensure "$app" || true
        app_log_links "$app" deploy.log || true
    fi
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

# A deploy that Deployer stopped on its clock says so inside a PHP exception:
# "The command "…" exceeded the timeout of 300 seconds". In plain words, under
# "Deploy failed": which step it was — and, when it is the build of a recipe
# without the build's own limit (written before 5.18.0 and edited by hand, so
# the migration left it alone), the command that gives it one.
_deploy_timeout_note() {   # <app> <deploy log>
    local app="${1:-}" lf="${2:-}" run secs step
    [[ -n "$app" && -f "$lf" ]] || return 0
    # This run: from its start banner to the end of the log.
    run=$(tail -n 600 -- "$lf" 2>/dev/null | awk '/===== deploy start /{ buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }')
    secs=$(awk 'match($0, /exceeded the timeout of [0-9]+ seconds/) { s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); print s; exit }' <<< "$run")
    [[ "$secs" =~ ^[0-9]+$ ]] || return 0
    step=$(awk '/\] task [A-Za-z0-9:_-]+$/ { t = $NF } /exceeded the timeout of [0-9]+ seconds/ { print t; exit }' <<< "$run")
    case "$step" in
        cipi:node_build|node:install|node:build)
            if app_read "$app" "/home/${app}/.deployer/deploy.php" 2>/dev/null | grep -q 'cipi:build-timeout'; then
                warn "The build (${step}) was stopped after $((secs / 60)) minutes, the most it is given (cipi_build_timeout in deploy.php)."
                warn "What it was doing when it stopped: cipi deploy ${app} --log"
            else
                warn "The build (${step}) was stopped at the ${secs} seconds Deployer gives any command: this deploy.php"
                warn "does not have the 30 minutes Cipi gives a build. To have them, let Cipi write the recipe again"
                warn "(edits made to deploy.php by hand are lost): $(deployer_recipe_again_cmd "$app")"
            fi
            ;;
        *)
            warn "The step ${step:-of the deploy} was stopped after ${secs} seconds, the most Deployer gives a command."
            warn "What it was doing when it stopped: cipi deploy ${app} --log"
            ;;
    esac
    return 0
}

deploy_command() {
    local app="${1:-}"; shift||true
    [[ -z "$app" ]] && { error "Usage: cipi deploy <app> [--rollback|--releases|--history|--last|--log|--status|--key|--webhook|--snapshot|--snapshot-required|--rollback-on-unhealthy]  ·  cipi deploy --last"; exit 1; }
    # The two forms that only read, with the flag first: every app's last
    # run, and one app's history. A Cipi older than 5.9.0 takes the flag for
    # an app name and answers "not found"; `cipi deploy <app> --history` on
    # it would deploy. A panel that cannot be sure of the version uses these.
    case "$app" in
        --last)
            parse_args "$@"; _deploy_last ""; return ;;
        --history)
            app="${1:-}"; shift||true
            [[ -n "$app" && "$app" != --* ]] || { error "Usage: cipi deploy --history <app> [--limit=N] [--json]"; exit 1; }
            app_exists "$app" || { error "App '$app' not found"; exit 1; }
            parse_args "$@"; _deploy_history "$app"; return ;;
    esac
    app_exists "$app" || { error "App '$app' not found"; exit 1; }
    parse_args "$@"

    if   [[ "${ARG_rollback:-}" == "true" ]];        then _deploy_rollback "$app"
    elif [[ "${ARG_history:-}" == "true" ]];         then _deploy_history "$app"
    elif [[ "${ARG_last:-}" == "true" ]];            then _deploy_last "$app"
    elif [[ -n "${ARG_log:-}" ]];                    then _deploy_log_show "$app" "${ARG_log}"
    elif [[ "${ARG_releases:-}" == "true" ]];        then _deploy_releases "$app"
    elif [[ "${ARG_key:-}" == "true" ]];             then _deploy_key "$app"
    elif [[ "${ARG_webhook:-}" == "true" ]];         then _deploy_webhook "$app"
    elif [[ "${ARG_unlock:-}" == "true" ]];          then _deploy_unlock "$app"
    elif [[ -n "${ARG_trust_host:-}" ]];             then _deploy_trust_host "$app" "${ARG_trust_host}"
    elif [[ "${ARG_audit:-}" == "true" ]];           then _deploy_audit_show "$app"
    elif [[ "${ARG_status:-}" == "true" ]];          then _deploy_status "$app"
    else _deploy_run "$app"
    fi
}

# Commit ids on stdin, one per line → {"<id>": "<first line of its message>"}.
# Read from the app's own clone (Deployer's mirror, or htdocs for a custom app
# deployed with git pull) as the app user — root never runs git in a
# repository an app can write — with one git process for all of them. A commit
# the clone no longer has is left out; control characters become spaces and a
# subject is cut at 200 characters, because whoever can push chooses it.
_deploy_commit_subjects() {
    local app="$1" home dir="" c
    home=$(_deploy_app_home "$app")
    local -a ids=()
    while IFS= read -r c; do
        [[ "$c" =~ ^[0-9a-f]{7,40}$ ]] && ids+=("$c")
    done
    (( ${#ids[@]} > 0 )) || { echo '{}'; return 0; }
    for c in "${home}/.dep/repo" "${home}/htdocs/.git"; do
        if app_as "$app" test -d "$c" 2>/dev/null; then dir="$c"; break; fi
    done
    [[ -n "$dir" ]] || { echo '{}'; return 0; }
    app_as "$app" timeout 15 git --git-dir="$dir" log --no-walk=unsorted --ignore-missing \
            --format='%H%x1f%s' "${ids[@]}" 2>/dev/null < /dev/null \
        | jq -R -s 'split("\n") | map(select(length > 0) | split("\u001f")
                    | {key: .[0], value: ((.[1:] | join(" ")) | gsub("[\u0000-\u001f\u007f]"; " ") | .[0:200])})
                    | map(select(.key | test("^[0-9a-f]{40}$"))) | from_entries'
}

# Where an app's home is. A function, so tests can point it elsewhere.
_deploy_app_home() { echo "/home/$1"; }

# cipi deploy <app> --audit [--days=90] [--json] — this app's records from the
# deploy audit ledger (lib/cipi-deploy-audit.sh).
_deploy_audit_show() {
    local app="$1" ledger="${CIPI_LOG}/deploys.jsonl" days="${ARG_days:-90}" since
    [[ "$days" =~ ^[0-9]{1,4}$ ]] || { error "--days must be a number"; exit 1; }
    if [[ ! -f "$ledger" ]]; then
        warn "No deploy audit ledger yet (${ledger}) — it is written from the first deploy after cipi self-update"
        return 0
    fi
    since=$(date -u -d "-${days} days" '+%Y-%m-%dT%H:%M:%SZ')
    if [[ "${ARG_json:-}" == "true" ]]; then
        # Each record gets the first line of its commit's message as `subject`,
        # read now from the app's clone. It is not in the ledger and no hash
        # covers it: the record says which commit went live, the clone says
        # what that commit is called.
        local records subjects
        records=$(jq -c --arg a "$app" --arg s "$since" 'select(.app == $a and .ts >= $s)' "$ledger" | jq -s .)
        subjects=$(jq -r '[.[].commit // "" | select(test("^[0-9a-f]{7,40}$"))] | unique | .[]' <<< "$records" 2>/dev/null \
            | _deploy_commit_subjects "$app" 2>/dev/null || true)
        jq -e 'type == "object"' <<< "${subjects:-}" >/dev/null 2>&1 || subjects='{}'
        jq --argjson s "$subjects" 'map(if ((.commit // "") != "") and (($s[.commit] // "") != "") then . + {subject: $s[.commit]} else . end)' <<< "$records"
        return 0
    fi
    echo -e "\n${BOLD}Deploy audit — ${app}${NC} ${DIM}(last ${days} days, ${ledger})${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local rows
    rows=$(jq -r --arg a "$app" --arg s "$since" 'select(.app == $a and .ts >= $s) | [
        .ts, .event, (.release // "-"), ((.commit // "")[0:10] | if . == "" then "-" else . end),
        (.origin + (if (.trigger // "") != "" then "/" + .trigger else "" end)),
        (if (.operator // "") != "" then .operator else "-" end),
        (if (.ip // "") != "" then .ip else "-" end),
        ([.claimed // {} | to_entries[] | "\(.key)=\(.value)"] | join(" "))
    ] | @tsv' "$ledger" 2>/dev/null)
    if [[ -z "$rows" ]]; then
        echo -e "  ${DIM}No records${NC}\n"; return 0
    fi
    tbl_start
    tbl_head "TIME (UTC)" "EVENT" "RELEASE" "COMMIT" "ORIGIN" "OPERATOR" "IP" "CLAIMED"
    local ts ev rel sha org op ip cl
    while IFS=$'\t' read -r ts ev rel sha org op ip cl; do
        tbl_row "${ts/T/ }" "$ev" "$rel" "$sha" "$org" "$op" "$ip" "${DIM}${cl}${NC}"
    done <<< "$rows"
    tbl_print
    echo ""
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
        # Kept in memory for _deploy_run. It went through
        # /tmp/cipi-predeploy-<app>.path: a name any local user could create
        # first, and whatever path it then held was the one a failed deploy
        # told the admin to restore.
        CIPI_PREDEPLOY_SNAPSHOT="$dump"
        return 0
    fi

    cipi_notify \
        "Cipi pre-deploy snapshot failed: ${app} on $(hostname)" \
        "Database dump before deploy failed.\n\nServer: $(hostname)\nApp: ${app}\nEngine: ${eng}\nTime: $(notify_now)" \
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

    # One deploy at a time. While Deployer runs it holds .dep/deploy.lock, and
    # this one would only be refused by it — after a database snapshot, and
    # reported as a failed deploy. A lock with no Deployer alive was left by a
    # deploy that was interrupted (a reboot, a kill; one that fails releases
    # its own): it is removed here, nobody has to run --unlock first.
    if [[ -f "${home}/.dep/deploy.lock" ]]; then
        if grep -q $'\tdep$' <<< "$(_deploy_live_pids "$app")"; then
            error "A deploy of '${app}' is running — wait for it: cipi deploy ${app} --status"
            exit 1
        fi
        app_rm "$app" "${home}/.dep/deploy.lock" || true
        info "Removed the lock left by an interrupted deploy"
        log_action "DEPLOY UNLOCK: $app (stale lock, no deploy running)"
    fi

    # Legacy per-file ACLs on laravel-*.log break deploy:writable chmod — strip before Deployer runs.
    ensure_app_logs_permissions "$app" || true

    CIPI_PREDEPLOY_SNAPSHOT=""
    _deploy_predeploy_snapshot "$app" || exit 1
    local snapshot_path="${CIPI_PREDEPLOY_SNAPSHOT:-}"

    local lf; lf=$(deploy_log_file "$app")
    local branch_disp; branch_disp=$(app_get "$app" branch)
    local rel_before; rel_before=$(deploy_current_release "$app")
    local t0=$SECONDS

    # The start banner names who started this run — what `--status` and the
    # panel show while it runs: "panel" when the API started it (www-data,
    # through sudo), "cli" from a terminal. The audit ledger establishes the
    # origin on its own, from the process chain, and is not told anything here.
    local trigger="cli"
    [[ "${SUDO_USER:-}" == "www-data" ]] && trigger="panel"
    deploy_log_open "$app" "$trigger" "$branch_disp" "$rel_before"

    info "Deploying '${app}'..."
    echo ""

    # `set -e` would abort the whole `cipi` process the moment Deployer exits
    # non-zero — the failure branch below (and its deploy_fail notification)
    # was unreachable. Disable it around the run and read the real status from
    # PIPESTATUS[0]; the pipe adds a wall-clock timestamp to every logged line.
    local rc=0 had_e=0
    [[ $- == *e* ]] && had_e=1
    set +e
    # CIPI_DEPLOY_TRIGGER sits in the environment of this root sudo process,
    # where cipi-deploy-audit reads it back to tell a CLI deploy from the rest.
    CIPI_DEPLOY_TRIGGER=cli sudo -u "$app" bash -c "cd ${home} && /usr/bin/php${php_ver} /usr/local/bin/dep deploy -f ${df} 2>&1" \
        | deploy_log_tee "$lf"
    rc=${PIPESTATUS[0]}
    [[ $had_e -eq 1 ]] && set -e

    local rel_after; rel_after=$(deploy_current_release "$app")
    local secs=$(( SECONDS - t0 ))
    echo ""

    if [[ $rc -eq 0 ]]; then
        deploy_log_close "$app" "OK" "$rel_after" "$secs" "$rc"
        success "Deploy completed${rel_after:+  (release ${rel_after}, ${secs}s)}"
        # A commit whose automatic deploy failed is paused (cipi-app-deploy);
        # a deploy by hand that goes through resumes them.
        [[ -f "${home}/.dep/cipi-paused-commit" ]] && app_rm "$app" "${home}/.dep/cipi-paused-commit"
        log_action "DEPLOY OK: $app release=${rel_after:-?} in ${secs}s"
        # The success notification is sent after the release has been verified,
        # so it can state whether the app actually answers — reporting "deploy
        # succeeded" while the site returns 500 would be worse than silence.
        _deploy_apply_yml "$app"
        _deploy_horizon_detect "$app" || true
        # An Octane app deployed without a pinned FrankenPHP build: Octane
        # downloaded one at start. Pin those bytes, so the next deploy links
        # them instead of downloading whatever GitHub has then.
        if [[ "$(app_get "$app" octane)" == "frankenphp" ]]; then
            declare -f fphp_adopt >/dev/null 2>&1 || source "${CIPI_LIB}/frankenphp.sh"
            local _fb=""
            _fb=$(fphp_adopt "$app" 2>/dev/null) || _fb=""
            [[ -n "$_fb" ]] && info "FrankenPHP: pinned the binary Octane downloaded (${_fb}) — later deploys link it (cipi frankenphp status)"
        fi
        local post_line post_rc=0
        post_line=$(_deploy_run_post_deploy "$app") || post_rc=$?
        local health_line; health_line=$(_deploy_health_check "$app")
        # The nginx page cache (cipi cache <app> on): the pages of the release
        # before name its assets. Before Cloudflare's purge, so that the edge
        # fetches the new pages and not what nginx still held.
        local cache_line=""
        if [[ -n "$(app_get "$app" page_cache)" ]]; then
            declare -f cache_after_deploy >/dev/null 2>&1 || source "${CIPI_LIB}/cache.sh" 2>/dev/null || true
            if declare -f cache_after_deploy >/dev/null 2>&1; then
                cache_line=$(cache_after_deploy "$app" 2>/dev/null) || cache_line=""
                [[ -n "$cache_line" ]] && info "$cache_line"
            fi
        fi
        # cipi zt purge <app> --on-deploy=on: Cloudflare's cache of the app's
        # hostnames, once the new release answers.
        local purge_line=""
        if [[ "$(app_get "$app" cf_purge)" == "true" ]]; then
            declare -f zt_purge_after_deploy >/dev/null 2>&1 || source "${CIPI_LIB}/zt.sh" 2>/dev/null || true
            if declare -f zt_purge_after_deploy >/dev/null 2>&1; then
                purge_line=$(zt_purge_after_deploy "$app" 2>/dev/null) || purge_line=""
                [[ -n "$purge_line" ]] && info "$purge_line"
            fi
        fi
        if [[ -x /usr/local/bin/cipi-scan-manifest ]]; then
            /usr/local/bin/cipi-scan-manifest "$app" >/dev/null 2>&1 || true
        fi
        [[ $post_rc -ne 0 ]] && warn "Post-deploy steps failed — see the deploy log."
        local yml_mail=""
        [[ -n "${_DEPLOY_YML_LINE:-}" ]] && yml_mail="cipi.yml: ${_DEPLOY_YML_LINE}\n"
        cipi_notify \
            "Cipi deploy succeeded: ${app} release ${rel_after:-?} on $(hostname)" \
            "Deploy completed successfully.\n\n$(_deploy_release_details "$app" "$rel_after" "$branch_disp" "$secs")Previous release: ${rel_before:-none}\nPost-deploy: ${post_line}\n${yml_mail}Healthcheck: ${health_line}\n${cache_line:+${cache_line}\n}${purge_line:+${purge_line}\n}" \
            deploy_success
        # A plain return: `[[ … ]] && return` on this line was false (status 1)
        # whenever the steps passed, and under `set -e` that 1 became the exit
        # code of a deploy that had just published — the API and the panel
        # reported every successful deploy as failed.
        return "$post_rc"
    else
        deploy_log_close "$app" "FAILED" "$rel_after" "$secs" "$rc"
        error "Deploy failed (exit $rc)"
        _deploy_timeout_note "$app" "$lf"
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

# ── Horizon, noticed ─────────────────────────────────────────
#
# An app that requires laravel/horizon and puts its queues on Redis needs the
# Horizon process, and Cipi started it only when someone ran `cipi worker
# horizon enable`: until then the jobs piled up and nothing said why.
#
# After a successful deploy, what the app says about itself is read — the
# package in the release, QUEUE_CONNECTION in its .env — and:
#   - Horizon is switched on by itself in the one case where nothing can be
#     lost: the package is there, the queues are on Redis, and no queue:work
#     worker is configured (so nothing is processing those jobs today);
#   - in every other case it is a line of advice, said once: an app with
#     queue:work workers keeps them (Horizon would replace them), and the
#     .env is the app's — QUEUE_CONNECTION is suggested, never written.
# Never for an app where `cipi worker horizon disable` was run (horizon_auto),
# nor where cipi.yml or `cipi worker horizon enable` already decided.
# Prints "enable", "workers", "env:<value>" or nothing: what there is to do.
deploy_horizon_state() {
    local app="$1" home="/home/$1" conf="/etc/supervisor/conf.d/$1.conf" envtext qc
    [[ "$(app_get "$app" custom)" == "true" ]] && return 0
    [[ "$(app_get "$app" horizon)" == "true" ]] && return 0
    [[ "$(app_get "$app" horizon_auto)" == "off" ]] && return 0
    id "$app" &>/dev/null || return 0
    app_as "$app" test -f "${home}/current/vendor/laravel/horizon/composer.json" < /dev/null 2>/dev/null || return 0
    if grep -qsE '^\[program:.*-worker-' "$conf" 2>/dev/null; then
        echo "workers"; return 0
    fi
    envtext=$(app_read "$app" "${home}/shared/.env") || envtext=""
    qc=$(grep -m1 '^QUEUE_CONNECTION=' <<< "$envtext" | cut -d= -f2- | tr -d "\"' \r" || true)
    if [[ "$qc" == "redis" ]]; then echo "enable"; else echo "env:${qc:-unset}"; fi
    return 0
}

_deploy_horizon_detect() {
    local app="$1" state
    state=$(deploy_horizon_state "$app") || return 0
    [[ -n "$state" ]] || return 0
    if [[ "$state" == "enable" ]]; then
        step "laravel/horizon is installed, the queues are on Redis and no worker is configured — enabling Horizon..."
        # shellcheck source=/dev/null
        source "${CIPI_LIB}/worker.sh"
        # In a subshell: _horizon_enable exits on an incomplete app.
        ( _horizon_enable "$app" ) || warn "Horizon not enabled — run: cipi worker horizon enable ${app}"
        return 0
    fi
    # Advice is given once per situation, not at every deploy.
    [[ "$(app_get "$app" horizon_hint)" == "$state" ]] && return 0
    app_set "$app" horizon_hint "$state"
    if [[ "$state" == "workers" ]]; then
        info "laravel/horizon is installed and '${app}' runs queue:work workers. To hand its queues to Horizon instead: cipi worker horizon enable ${app}"
    else
        info "laravel/horizon is installed, but QUEUE_CONNECTION is '${state#env:}': Horizon works on Redis queues."
        echo -e "  Set it in the app's .env, then enable Horizon:"
        echo -e "    ${CYAN}cipi app env ${app} --set=QUEUE_CONNECTION=redis${NC}"
        echo -e "    ${CYAN}cipi worker horizon enable ${app}${NC}"
    fi
    return 0
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
    # A release made by Deployer 7 or 8 is an archive of the commit, not a
    # checkout: the commit is named in its REVISION and kept in Deployer's
    # mirror, ~/.dep/repo. Without this the notifications of every app
    # deployed that way had no Commit, Author or Committed line (5.17.0).
    if [[ ! -d "${dir}/.git" ]]; then
        local rev=""
        rev=$(app_as "$app" head -n 1 -- "${dir}/REVISION" 2>/dev/null < /dev/null | tr -cd '0-9a-f' || true)
        if [[ ${#rev} -ge 7 && ${#rev} -le 64 && -d "${home}/.dep/repo" ]]; then
            app_as "$app" timeout 15 git --git-dir="${home}/.dep/repo" --no-pager log -1 --format='%h|%s|%an|%ad' \
                --date=format:'%Y-%m-%d %H:%M' "$rev" 2>/dev/null < /dev/null || true
            return 0
        fi
        dir="${home}/current"
        [[ -d "${dir}/.git" ]] || return 0
    fi
    # git, as the app user: a repository carries its own configuration, and
    # root does not run git on one an app user controls (app_as in common.sh).
    # As root git refused these trees anyway ("dubious ownership") and the
    # line came back empty.
    app_as "$app" git --no-pager -C "$dir" log -1 --format='%h|%s|%an|%ad' --date=format:'%Y-%m-%d %H:%M' 2>/dev/null < /dev/null || true
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
    printf 'Time: %s\n' "$(notify_now)"
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

    # Behind basic auth, the routes of cipi/agent stay public when the release
    # has the agent (5.11.0): a release that adds or removes it rewrites the vhost.
    declare -f basicauth_agent_sync >/dev/null 2>&1 || source "${CIPI_LIB}/app.sh" 2>/dev/null || true
    declare -f basicauth_agent_sync >/dev/null 2>&1 && { basicauth_agent_sync "$app" || true; }

    local rc=0
    _deploy_post_release_verify_inner "$app" "$context" || rc=$?
    _deploy_metrics_event "$app" "$context" "$rc"
    return $rc
}

# One event per release put live, for `cipi metrics events` and the deploy
# markers on the panel's charts. Never fails the deploy.
_deploy_metrics_event() {
    local app="$1" context="$2" rc="$3" status=ok release=""
    declare -f metrics_event >/dev/null 2>&1 || source "${CIPI_LIB}/metrics.sh" 2>/dev/null || return 0
    declare -f deploy_current_release >/dev/null 2>&1 && release=$(deploy_current_release "$app" 2>/dev/null || true)
    [[ "$rc" == 1 ]] && status=crit
    metrics_event deploy "$app" "$status" "${context}${release:+ — release ${release}}${DEPLOY_VERIFY_SUMMARY:+ — healthcheck ${DEPLOY_VERIFY_SUMMARY}}"
    return 0
}

_deploy_post_release_verify_inner() {
    local app="$1" context="${2:-deploy}"

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
    CIPI_DEPLOY_TRIGGER=auto-rollback sudo -u "$app" bash -c "cd ${home} && /usr/bin/php${php_ver} /usr/local/bin/dep rollback -f ${home}/.deployer/deploy.php 2>&1" \
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
    # Stdout is the one-line summary the caller quotes in its notification. The
    # heading, the per-step lines and the verdict go to stderr, where a terminal
    # and the API's job output see them (before, they were captured into the
    # summary and reached the mail only).
    { echo ""; step "Post-deploy steps (cipi.yml)..."; } >&2
    set +e
    summary=$(_yml_post_deploy_run "$app" "$php_ver" "$lf" false root)
    rc=$?
    set -e
    chown "${app}:www-data" "$lf" 2>/dev/null || true
    if [[ $rc -eq 0 ]]; then
        success "Post-deploy: ${summary}" >&2
    else
        error "Post-deploy: ${summary}"
    fi
    printf '%s' "$summary"
    return "$rc"
}

_deploy_yml_line() {
    # $1 = deploy log  $2 = first line of this apply (older deploys share the file)
    local lf="$1" mark="${2:-1}" raw
    raw=$(tail -n +"$mark" "$lf" 2>/dev/null | grep 'cipi.yml-result:' | tail -1 | sed 's/.*cipi.yml-result: //' || true)
    case "$raw" in
        applied=*) echo "applied ${raw#applied=} change(s)" ;;
        unchanged) echo "already matches" ;;
        no-file)   echo "no cipi.yml in this release" ;;
        blocked)   echo "NOT applied — the plan was blocked (see the deploy log)" ;;
        invalid)   echo "NOT applied — cipi.yml failed validation (see the deploy log)" ;;
        disabled)  echo "NOT applied — auto-apply is not enabled" ;;
        failed=*)  echo "NOT applied cleanly (${raw}) — see the deploy log" ;;
        "")        echo "" ;;
        *)         echo "$raw" ;;
    esac
}

_deploy_apply_yml() {
    local app="$1"
    _DEPLOY_YML_LINE=""
    [[ "$(app_get "$app" yml_auto)" == "true" ]] || return 0

    local lf; lf=$(deploy_log_file "$app")
    echo ""
    step "Applying cipi.yml..."
    printf '[%(%Y-%m-%d %H:%M:%S)T] ===== cipi.yml apply =====\n' -1 >> "$lf" 2>/dev/null || true
    local mark; mark=$(wc -l < "$lf" 2>/dev/null || echo 0)

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
    _DEPLOY_YML_LINE=$(_deploy_yml_line "$lf" "$((mark + 1))")
    if [[ -z "$_DEPLOY_YML_LINE" ]]; then
        if [[ $rc -ne 0 ]]; then
            _DEPLOY_YML_LINE="NOT applied — see ${lf}"
        else
            _DEPLOY_YML_LINE="ok"
        fi
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

# ── Is a deploy running? ─────────────────────────────────────
#
# cipi deploy <app> --status [--json] [--tail=N]
#
# Both deploy paths write the same two banners to the app's deploy log: one
# when they start and one when they finish, whoever started them — `cipi
# deploy`, the panel, a Git push through the webhook, cipi/agent, a rollback.
# A start with no end after it is a deploy in flight, as long as something is
# still working on it: Deployer itself, the webhook wrapper (cipi-app-deploy)
# or the `cipi deploy` that started it, which run the post-deploy steps and
# the healthcheck once Deployer has finished. With nothing alive any more it
# was interrupted (a reboot, a kill) and the lock it left behind is removed by
# the next deploy (or --unlock). A ~/.deploy-trigger the per-minute cron has
# not picked up yet is a push about to deploy: queued — also while a deploy
# runs, since cipi-app-deploy puts it back until that one is over. A commit
# whose automatic deploy failed is paused (paused_commit) until a new push, a
# deploy by hand that succeeds, or --unlock.
#
# This is what the panel polls to show a deploy it did not start. The output
# never changes anything, so it is safe at any moment, as often as needed.

# Seconds since the epoch for a "YYYY-mm-dd HH:MM:SS" banner timestamp (local
# time, as the log writes it). GNU date on the servers; BSD date in the tests.
_deploy_epoch() {
    local ts="$1" e=""
    e=$(date -d "$ts" +%s 2>/dev/null) || e=$(date -j -f '%Y-%m-%d %H:%M:%S' "$ts" +%s 2>/dev/null) || e=""
    [[ "$e" =~ ^[0-9]+$ ]] || e=""
    echo "$e"
}

# ISO 8601 with the server's UTC offset, from seconds since the epoch — a
# banner's local time means nothing to a panel in another timezone.
_deploy_iso() {
    local e="$1" s=""
    [[ "$e" =~ ^[0-9]+$ ]] || { echo ""; return 0; }
    s=$(date -d "@${e}" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null) || s=$(date -r "$e" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null) || s=""
    echo "$s"
}

# "<pid>\t<kind>" per live process that belongs to a deploy of this app:
#   dep      Deployer (both paths run it as the app user), deploying or rolling back
#   wrapper  cipi-app-deploy, the webhook path, before and after Deployer
#   cli      a `cipi deploy <app>` that deploys or rolls back — not this
#            --status, nor --log, --audit and the other forms that only read
_deploy_live_pids() {
    local app="$1" pid args rest
    ps axww -o pid=,args= 2>/dev/null | while read -r pid args; do
        [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
        case "$args" in
            *"dep deploy -f /home/${app}/.deployer/deploy.php"*|*"dep rollback -f /home/${app}/.deployer/deploy.php"*)
                printf '%s\tdep\n' "$pid" ;;
            *"cipi-app-deploy ${app} "*)
                printf '%s\twrapper\n' "$pid" ;;
            *"/cipi deploy ${app}"|*"/cipi deploy ${app} "*)
                rest=" ${args#*/cipi deploy ${app}} "
                case "$rest" in
                    *" --status"*|*" --log"*|*" --releases"*|*" --key"*|*" --webhook"*|*" --unlock"*|*" --trust-host"*|*" --audit"*|*" --history"*|*" --last"*) ;;
                    *) printf '%s\tcli\n' "$pid" ;;
                esac ;;
        esac
    done
}

_deploy_status() {
    local app="$1" tail_n="${ARG_tail:-0}"
    [[ "$tail_n" =~ ^[0-9]{1,3}$ ]] || { error "--tail must be a number of lines (1-500)"; exit 1; }
    [[ "$tail_n" -le 500 ]] || tail_n=500
    local home lf; home=$(deploy_app_home "$app"); lf=$(deploy_log_file "$app")

    local re_start='^\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})\] ===== deploy start +app=[^ ]+ trigger=([^ ]+) branch=([^ ]+) from-release=([^ ]+) =====$'
    local re_end='^\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})\] ===== deploy (ROLLBACK )?(OK|FAILED) +app=[^ ]+ release=([^ ]+) duration=([0-9]+)s exit=(-?[0-9]+) =====$'

    # One pass over the banners: the last start, the last end, and the start
    # that belongs to that end. A start after the last end is an open run.
    local n line start_no=0 start_line="" end_no=0 end_line="" end_start_line=""
    if [[ -f "$lf" ]]; then
        while IFS= read -r line; do
            n="${line%%:*}"; line="${line#*:}"
            if [[ "$line" =~ $re_start ]]; then
                start_no=$n; start_line=$line
            elif [[ "$line" =~ $re_end ]]; then
                end_no=$n; end_line=$line; end_start_line=$start_line
            fi
        done < <(grep -n '\] ===== deploy ' "$lf" 2>/dev/null || true)
    fi

    local queued=false locked=false paused=""
    [[ -f "${home}/.deploy-trigger" ]] && queued=true
    [[ -f "${home}/.dep/deploy.lock" ]] && locked=true
    [[ -f "${home}/.dep/cipi-paused-commit" ]] && paused=$(app_read "$app" "${home}/.dep/cipi-paused-commit" 2>/dev/null | sed -n 1p | tr -cd '0-9a-f')
    local pids; pids=$(_deploy_live_pids "$app")
    local pid_list=""; [[ -n "$pids" ]] && pid_list=$(cut -f1 <<< "$pids" | tr '\n' ' ')

    local state="idle" phase="" has_cur=false
    local cur_trigger="" cur_branch="" cur_from="" cur_started="" cur_epoch="" cur_elapsed=""
    if [[ $start_no -gt $end_no && "$start_line" =~ $re_start ]]; then
        has_cur=true
        cur_started="${BASH_REMATCH[1]}"; cur_trigger="${BASH_REMATCH[2]}"
        cur_branch="${BASH_REMATCH[3]}";  cur_from="${BASH_REMATCH[4]}"
        cur_epoch=$(_deploy_epoch "$cur_started")
        [[ -n "$cur_epoch" ]] && cur_elapsed=$(( $(date +%s) - cur_epoch ))
        if [[ -n "$pids" ]]; then state="running"; else state="interrupted"; fi
    elif [[ -n "$pids" ]]; then
        # Alive without a banner: `dep deploy` run by hand as the app user,
        # or a run that has not written its first line yet.
        has_cur=true; state="running"
    elif [[ "$queued" == true ]]; then
        state="queued"
    fi
    if [[ "$state" == "running" ]]; then
        phase="post-deploy"; grep -q $'\tdep$' <<< "$pids" && phase="deploy"
    fi

    local last_result="" last_kind="" last_release="" last_duration="" last_exit="" last_finished="" last_fin_epoch=""
    local last_trigger="" last_branch="" last_from="" last_started="" last_start_epoch=""
    if [[ -n "$end_line" && "$end_line" =~ $re_end ]]; then
        last_finished="${BASH_REMATCH[1]}"
        last_kind="deploy"; [[ -n "${BASH_REMATCH[2]}" ]] && last_kind="rollback"
        last_result="ok"; [[ "${BASH_REMATCH[3]}" == "FAILED" ]] && last_result="failed"
        last_release="${BASH_REMATCH[4]}"; last_duration="${BASH_REMATCH[5]}"; last_exit="${BASH_REMATCH[6]}"
        last_fin_epoch=$(_deploy_epoch "$last_finished")
        if [[ -n "$end_start_line" && "$end_start_line" =~ $re_start ]]; then
            last_started="${BASH_REMATCH[1]}"; last_trigger="${BASH_REMATCH[2]}"
            last_branch="${BASH_REMATCH[3]}";  last_from="${BASH_REMATCH[4]}"
            last_start_epoch=$(_deploy_epoch "$last_started")
        fi
    fi

    local tail_text=""
    [[ "$tail_n" -gt 0 && -f "$lf" ]] && tail_text=$(tail -n "$tail_n" "$lf" 2>/dev/null || true)

    if [[ "${ARG_json:-}" == "true" ]]; then
        jq -n \
            --arg app "$app" --arg state "$state" --arg phase "$phase" \
            --argjson queued "$queued" --argjson locked "$locked" --argjson has_cur "$has_cur" --arg paused "$paused" \
            --arg ct "$cur_trigger" --arg cb "$cur_branch" --arg cf "$cur_from" \
            --arg cs "$(_deploy_iso "$cur_epoch")" --arg ce "$cur_elapsed" --arg pids "$pid_list" \
            --arg lr "$last_result" --arg lk "$last_kind" --arg lrel "$last_release" \
            --arg ld "$last_duration" --arg lx "$last_exit" --arg lf_at "$(_deploy_iso "$last_fin_epoch")" \
            --arg lt "$last_trigger" --arg lb "$last_branch" --arg lfrom "$last_from" \
            --arg ls_at "$(_deploy_iso "$last_start_epoch")" \
            --arg log "$lf" --argjson tail_n "$tail_n" --arg tail "$tail_text" '
            def nz: if . == "" then null else . end;
            def num: if . == "" then null else tonumber end;
            {app: $app, state: $state, running: ($state == "running"), phase: ($phase | nz),
             queued: $queued, locked: $locked, paused_commit: ($paused | nz),
             current: (if $has_cur then
                 {trigger: ($ct | nz), branch: ($cb | nz), from_release: ($cf | nz),
                  started_at: ($cs | nz), elapsed: ($ce | num),
                  pids: ($pids | split(" ") | map(select(. != "")) | map(tonumber))}
               else null end),
             last: (if $lr == "" then null else
                 {result: $lr, kind: $lk, release: ($lrel | nz), duration: ($ld | num), exit: ($lx | num),
                  trigger: ($lt | nz), branch: ($lb | nz), from_release: ($lfrom | nz),
                  started_at: ($ls_at | nz), finished_at: ($lf_at | nz)}
               end),
             log: $log}
            + (if $tail_n > 0 then {tail: ($tail | split("\n") | if length > 0 and .[-1] == "" then .[:-1] else . end)} else {} end)'
        return 0
    fi

    echo -e "\n${BOLD}Deploy status — ${app}${NC}\n"
    case "$state" in
        running)
            if [[ "$phase" == "deploy" ]]; then
                printf "  %-10s ${GREEN}running${NC} — Deployer is building the release\n" "State"
            else
                printf "  %-10s ${GREEN}running${NC} — post-deploy steps, cipi.yml, healthcheck\n" "State"
            fi ;;
        queued)      printf "  %-10s ${YELLOW}queued${NC} — a push is waiting for the per-minute cron\n" "State" ;;
        interrupted) printf "  %-10s ${RED}interrupted${NC} — the last run never wrote its end banner and nothing is running it\n" "State" ;;
        *)           printf "  %-10s idle\n" "State" ;;
    esac
    if [[ "$has_cur" == true ]]; then
        if [[ -n "$cur_trigger" ]]; then
            printf "  %-10s %s   branch %s   from release %s\n" "Trigger" "$cur_trigger" "$cur_branch" "$cur_from"
            printf "  %-10s %s" "Started" "$cur_started"
            [[ -n "$cur_elapsed" ]] && printf "  ${DIM}(%s ago)${NC}" "$(_deploy_fmt_secs "$cur_elapsed")"
            echo ""
        else
            printf "  %-10s ${DIM}not started by cipi (dep run by hand?) — pid %s${NC}\n" "Trigger" "${pid_list% }"
        fi
    fi
    [[ "$queued" == true && "$state" != "queued" ]] && printf "  %-10s a push is waiting — it deploys when this run ends\n" "Queued"
    if [[ "$locked" == true ]]; then
        if [[ "$state" == "interrupted" || "$state" == "idle" ]]; then
            printf "  %-10s ${YELLOW}present${NC} — left by an interrupted deploy: the next deploy removes it (or now: cipi deploy %s --unlock)\n" "Lock" "$app"
        else
            printf "  %-10s present (held by the run)\n" "Lock"
        fi
    fi
    if [[ -n "$paused" ]]; then
        printf "  %-10s ${YELLOW}automatic deploys of commit %s${NC} — it failed; a new push deploys, or by hand: cipi deploy %s\n" "Paused" "${paused:0:12}" "$app"
    fi
    if [[ -n "$last_result" ]]; then
        local verdict="${GREEN}OK${NC}"; [[ "$last_result" == "failed" ]] && verdict="${RED}FAILED${NC}"
        [[ "$last_kind" == "rollback" ]] && verdict="rollback ${verdict}"
        printf "  %-10s ${verdict} — release %s in %s, %s" "Last" "$last_release" "$(_deploy_fmt_secs "${last_duration:-0}")" "$last_finished"
        [[ -n "$last_trigger" ]] && printf "  ${DIM}(%s, branch %s)${NC}" "$last_trigger" "$last_branch"
        echo ""
    else
        printf "  %-10s ${DIM}no deploy recorded yet${NC}\n" "Last"
    fi
    printf "  %-10s %s\n" "Log" "$lf"
    if [[ -n "$tail_text" ]]; then
        echo -e "\n${DIM}── last ${tail_n} lines ──${NC}"
        printf '%s\n' "$tail_text"
    fi
    echo ""
    return 0
}

# ── History: the banners, across the rotated files ───────────
#
# deploy.log is rotated every night (copytruncate, cipi-app-logs in
# /etc/logrotate.d): the runs of the days before are in deploy.log.1 and
# deploy.log.N.gz. Whatever reads deploy.log alone — the panel did, through
# the app-logs endpoint — has the duration of a deploy until the first night
# and never again. A deploy somebody starts is watched while it runs; one a
# push starts is looked at the day after, so it was the webhook deploys that
# "did not save their time".
#
# The files of one deploy log, newest first. The directory is root's and the
# app user cannot add a name to it: the glob is a list of files logrotate made.
_deploy_log_files() {   # <app>
    local lf f
    lf=$(deploy_log_file "$1")
    [[ -f "$lf" && ! -L "$lf" ]] && printf '%s\n' "$lf"
    # shellcheck disable=SC2012
    while IFS= read -r f; do
        [[ -n "$f" && -f "$f" && ! -L "$f" ]] && printf '%s\n' "$f"
    done < <(ls -1t -- "${lf}".* "${lf}"-* 2>/dev/null || true)
    return 0
}

# A banner's local time as ISO 8601 with the offset in force that day; empty
# for a time `date` cannot read (the app user can write to its own log).
_deploy_ts_iso() {
    [[ -n "${1:-}" ]] || { echo ""; return 0; }
    date -d "$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || echo ""
}

# Up to <limit> finished runs of an app, newest first, one per line:
#   finished, kind, result, release, duration, exit, started, trigger, branch, from
# separated by US (0x1f) — not whitespace, so `read` keeps an empty field, and
# not a character a banner's fields can hold. Files are read newest first and
# only as far back as it takes.
_deploy_history_rows() {   # <app> <limit>
    local app="$1" limit="${2:-30}" f chunk all="" ends=0 n
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        chunk=$(gzip -cdf -- "$f" 2>/dev/null | grep -a '\] ===== deploy ' || true)
        [[ -n "$chunk" ]] || continue
        all="${chunk}"$'\n'"${all}"
        n=$(grep -cE '\] ===== deploy (ROLLBACK )?(OK|FAILED) ' <<< "$chunk" || true)
        ends=$(( ends + ${n:-0} ))
        (( ends >= limit )) && break
    done < <(_deploy_log_files "$app")
    [[ -n "$all" ]] || return 0

    local re_start='^\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})\] ===== deploy start +app=[^ ]+ trigger=([^[:space:][:cntrl:]]+) branch=([^[:space:][:cntrl:]]+) from-release=([^[:space:][:cntrl:]]+) =====$'
    local re_end='^\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})\] ===== deploy (ROLLBACK )?(OK|FAILED) +app=[^ ]+ release=([^[:space:][:cntrl:]]+) duration=([0-9]+)s exit=(-?[0-9]+) =====$'
    local line s_ts="" s_tr="" s_br="" s_from="" kind result rows="" u=$'\x1f'
    while IFS= read -r line; do
        if [[ "$line" =~ $re_start ]]; then
            s_ts="${BASH_REMATCH[1]}"; s_tr="${BASH_REMATCH[2]}"; s_br="${BASH_REMATCH[3]}"; s_from="${BASH_REMATCH[4]}"
        elif [[ "$line" =~ $re_end ]]; then
            kind="deploy"; [[ -n "${BASH_REMATCH[2]}" ]] && kind="rollback"
            result="ok"; [[ "${BASH_REMATCH[3]}" == "FAILED" ]] && result="failed"
            rows+="${BASH_REMATCH[1]}${u}${kind}${u}${result}${u}${BASH_REMATCH[4]}${u}${BASH_REMATCH[5]}${u}${BASH_REMATCH[6]}${u}${s_ts}${u}${s_tr}${u}${s_br}${u}${s_from}"$'\n'
            # The start belongs to this end only.
            s_ts=""; s_tr=""; s_br=""; s_from=""
        fi
    done <<< "$all"
    [[ -n "$rows" ]] || return 0
    printf '%s' "$rows" | tail -n "$limit" | tac
    return 0
}

# Rows of _deploy_history_rows as a JSON array (same keys as "last" in
# `cipi deploy <app> --status --json`).
_deploy_history_json() {   # stdin: rows
    local fin kind result rel dur ex st tr br from out="[]" items=()
    while IFS=$'\x1f' read -r fin kind result rel dur ex st tr br from; do
        [[ -n "$fin" ]] || continue
        items+=("$(jq -cn \
            --arg result "$result" --arg kind "$kind" --arg rel "$rel" --arg dur "$dur" --arg ex "$ex" \
            --arg tr "$tr" --arg br "$br" --arg from "$from" \
            --arg st "$(_deploy_ts_iso "$st")" --arg fin "$(_deploy_ts_iso "$fin")" '
            def nz: if . == "" then null else . end;
            {result: $result, kind: $kind, release: ($rel | nz), duration: ($dur | tonumber), exit: ($ex | tonumber),
             trigger: ($tr | nz), branch: ($br | nz), from_release: ($from | nz),
             started_at: ($st | nz), finished_at: ($fin | nz)}')")
    done
    if [[ ${#items[@]} -gt 0 ]]; then out=$(printf '%s\n' "${items[@]}" | jq -cs .); fi
    printf '%s\n' "$out"
}

# cipi deploy <app> --history [--limit=N] [--json]
# cipi deploy --history <app> …   the same, flag first: a Cipi that does not
#                                 know the flag answers "App '--history' not
#                                 found" to this form, and deploys on the other.
_deploy_history() {
    local app="$1" limit="${ARG_limit:-30}" rows
    [[ "$limit" =~ ^[0-9]{1,3}$ && "$limit" -ge 1 ]] || { error "--limit must be a number (1-500)"; exit 1; }
    [[ "$limit" -le 500 ]] || limit=500
    rows=$(_deploy_history_rows "$app" "$limit")
    if [[ "${ARG_json:-}" == "true" ]]; then
        jq -n --arg app "$app" --arg log "$(deploy_log_file "$app")" \
            --argjson runs "$(_deploy_history_json <<< "$rows")" \
            '{app: $app, count: ($runs | length), runs: $runs, log: $log}'
        return 0
    fi
    echo -e "\n${BOLD}Deploy history — ${app}${NC} ${DIM}(newest first, rotated logs included)${NC}"
    if [[ -z "$rows" ]]; then
        echo -e "  ${DIM}No deploy recorded yet${NC}\n"; return 0
    fi
    tbl_start
    tbl_head "FINISHED" "RESULT" "RELEASE" "TOOK" "TRIGGER" "BRANCH"
    local fin kind result rel dur ex st tr br from verdict
    while IFS=$'\x1f' read -r fin kind result rel dur ex st tr br from; do
        [[ -n "$fin" ]] || continue
        verdict="${GREEN}OK${NC}"; [[ "$result" == "failed" ]] && verdict="${RED}FAILED${NC} ${DIM}(exit ${ex})${NC}"
        [[ "$kind" == "rollback" ]] && verdict="rollback ${verdict}"
        tbl_row "$fin" "$verdict" "$rel" "$(_deploy_fmt_secs "$dur")" "$tr" "$br"
    done <<< "$rows"
    tbl_print
    echo ""
    return 0
}

# cipi deploy --last [--json] — the last finished run of every app (the app
# list of the panel shows when each one was last deployed, and how it went).
# cipi deploy <app> --last [--json] — of one.
_deploy_last() {
    local only="${1:-}" names app row
    if [[ -n "$only" ]]; then
        names="$only"
    else
        names=$(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
    fi
    if [[ "${ARG_json:-}" == "true" ]]; then
        local obj="{}" one
        while IFS= read -r app; do
            [[ -n "$app" ]] || continue
            row=$(_deploy_history_rows "$app" 1)
            one=$(_deploy_history_json <<< "$row" | jq -c '.[0] // null')
            obj=$(jq -c --arg a "$app" --argjson v "$one" '.[$a] = $v' <<< "$obj")
        done <<< "$names"
        jq -n --argjson apps "$obj" '{apps: $apps}'
        return 0
    fi
    echo -e "\n${BOLD}Last deploy${NC}"
    if [[ -z "$names" ]]; then
        echo -e "  ${DIM}No apps${NC}\n"; return 0
    fi
    tbl_start
    tbl_head "APP" "FINISHED" "RESULT" "RELEASE" "TOOK" "TRIGGER"
    local fin kind result rel dur ex st tr br from verdict
    while IFS= read -r app; do
        [[ -n "$app" ]] || continue
        row=$(_deploy_history_rows "$app" 1)
        if [[ -z "$row" ]]; then
            tbl_row "${CYAN}${app}${NC}" "${DIM}never${NC}" "" "" "" ""
            continue
        fi
        IFS=$'\x1f' read -r fin kind result rel dur ex st tr br from <<< "$row"
        verdict="${GREEN}OK${NC}"; [[ "$result" == "failed" ]] && verdict="${RED}FAILED${NC}"
        [[ "$kind" == "rollback" ]] && verdict="rollback ${verdict}"
        tbl_row "${CYAN}${app}${NC}" "$fin" "$verdict" "$rel" "$(_deploy_fmt_secs "$dur")" "$tr"
    done <<< "$names"
    tbl_print
    echo ""
    return 0
}

# Removes the Deployer lock — which a deploy that fails releases by itself, and
# the next deploy removes when no Deployer is alive — and resumes the automatic
# deploys of a commit that failed (~/.dep/cipi-paused-commit).
_deploy_unlock() {
    local app="$1"
    local home="/home/${app}"
    local lockfile="${home}/.dep/deploy.lock" pausefile="${home}/.dep/cipi-paused-commit" done=false c=""
    if [[ -f "$lockfile" ]]; then
        app_rm "$app" "$lockfile" || true
        success "Deploy unlocked — run: cipi deploy ${app}"
        log_action "DEPLOY UNLOCK: $app"
        done=true
    fi
    if [[ -f "$pausefile" ]]; then
        c=$(app_read "$app" "$pausefile" 2>/dev/null | sed -n 1p | tr -cd '0-9a-f')
        app_rm "$app" "$pausefile" || true
        success "Automatic deploys resumed${c:+ — commit ${c:0:12} deploys again on the next push or webhook}"
        log_action "DEPLOY RESUME: $app ${c:0:12}"
        done=true
    fi
    [[ "$done" == true ]] || info "No deploy lock found for '${app}'"
    return 0
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
    CIPI_DEPLOY_TRIGGER=rollback sudo -u "$app" bash -c "cd ${home} && /usr/bin/php${php_ver} /usr/local/bin/dep rollback -f ${home}/.deployer/deploy.php 2>&1" \
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
        # The page cache holds the pages of the release that was just left.
        if [[ -n "$(app_get "$app" page_cache)" ]]; then
            declare -f cache_after_deploy >/dev/null 2>&1 || source "${CIPI_LIB}/cache.sh" 2>/dev/null || true
            if declare -f cache_after_deploy >/dev/null 2>&1; then
                local rb_cache=""
                rb_cache=$(cache_after_deploy "$app" 2>/dev/null) || rb_cache=""
                [[ -n "$rb_cache" ]] && info "$rb_cache"
            fi
        fi
        success "Rollback done${rel_after:+  (now on release ${rel_after})}"
        log_action "ROLLBACK OK: $app ${rel_before:-?} → ${rel_after:-?}"
        cipi_notify \
            "Cipi deploy rollback: ${app} on $(hostname)" \
            "Deploy rollback completed.\n\nServer: $(hostname)\nApp: ${app}\nRelease: ${rel_before:-?} → ${rel_after:-?}\nTime: $(notify_now)" \
            deploy_rollback
    else
        deploy_log_close "$app" "ROLLBACK FAILED" "$rel_after" "$secs" "$rc"
        error "Rollback failed (exit $rc)"
        warn "Log: ${lf}"
        log_action "ROLLBACK FAIL: $app exit=$rc"
        cipi_notify \
            "Cipi deploy rollback failed: ${app} on $(hostname)" \
            "Rollback exited with code ${rc}.\n\nServer: $(hostname)\nApp: ${app}\nRelease still live: ${rel_after:-?}\nTime: $(notify_now)\n\nLast lines of ${lf}:\n$(tail -n 30 "$lf" 2>/dev/null || echo '<log unreadable>')" \
            deploy_fail
        return "$rc"
    fi
}

# Release directories stay numeric (Deployer increments them, and rollback
# relies on that ordering). The date and the deployed commit are shown here
# instead, which is what the numbers alone failed to tell you.
# 54 → "54s", 125 → "2m05s", 3725 → "1h02m".
_deploy_fmt_secs() {
    local s="${1:-}"
    [[ "$s" =~ ^[0-9]+$ ]] || { printf '%s' "$s"; return 0; }
    if (( s < 60 )); then printf '%ds' "$s"
    elif (( s < 3600 )); then printf '%dm%02ds' $((s / 60)) $((s % 60))
    else printf '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60)); fi
}

# How long the deploy of release $2 took, from the end banner the deploy log
# carries for it ("===== deploy OK  app=x release=N duration=54s exit=0").
# The last banner of that release wins. The log is rotated every night, so the
# rotated files are read too (newest first, until one has it). Empty when
# none has it: a release deployed before 5.6.0, or older than the logs kept.
_deploy_release_took() {
    local app="$1" rel="$2" lf f secs=""
    lf=$(deploy_log_file "$app")
    # shellcheck disable=SC2012
    while IFS= read -r f; do
        [[ -n "$f" && -f "$f" && ! -L "$f" ]] || continue
        secs=$(gzip -cdf -- "$f" 2>/dev/null | grep -aoE "deploy OK  app=${app} release=${rel} duration=[0-9]+s" | tail -1 | grep -oE '[0-9]+s$' || true)
        [[ -n "$secs" ]] && break
    done < <(printf '%s\n' "$lf"; ls -1t -- "${lf}".* "${lf}"-* 2>/dev/null || true)
    [[ -n "$secs" ]] && _deploy_fmt_secs "${secs%s}"
    return 0
}

_deploy_releases() {
    local app="$1"
    local home="/home/${app}"
    [[ ! -d "${home}/releases" ]] && { info "No releases yet"; return; }
    local current=""
    [[ -L "${home}/current" ]] && current=$(readlink -f "${home}/current" | xargs basename)

    echo -e "\n${BOLD}Releases for '${app}'${NC}"
    printf "  ${BOLD}%-8s %-20s %-7s %-10s %s${NC}\n" "RELEASE" "DEPLOYED" "TOOK" "COMMIT" "SUBJECT"
    local r when sha subject mark took
    while read -r r; do
        [[ -n "$r" ]] || continue
        when=$(stat -c '%y' "${home}/releases/${r}" 2>/dev/null | cut -d. -f1)
        sha=""; subject=""
        if [[ -d "${home}/releases/${r}/.git" ]]; then
            # As the app user, one call for both (see _deploy_commit_info).
            local gl=""
            gl=$(app_as "$app" git --no-pager -C "${home}/releases/${r}" log -1 --format='%h|%s' 2>/dev/null < /dev/null || true)
            sha="${gl%%|*}"
            [[ "$gl" == *"|"* ]] && subject=$(printf '%s' "${gl#*|}" | cut -c1-46)
        fi
        took=$(_deploy_release_took "$app" "$r")
        mark=""; [[ "$r" == "$current" ]] && mark=" ${GREEN}← current${NC}"
        printf "  ${CYAN}%-8s${NC} %-20s %-7s %-10s %s%b\n" "$r" "${when:-—}" "${took:-—}" "${sha:-—}" "${subject:-—}" "$mark"
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
    echo -e "${CYAN}$(app_read "$app" "$kf" || true)${NC}\n"

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

    # ~/.ssh is the app user's: known_hosts and config are edited by that
    # user (app_as in common.sh), not by root following the names it finds.
    # Remove any existing entry for this host to avoid duplicates
    if [[ -f "$known_hosts" ]]; then
        app_as "$app" ssh-keygen -R "$host" -f "$known_hosts" &>/dev/null < /dev/null || true
        [[ "$port" != "22" ]] && app_as "$app" ssh-keygen -R "[${host}]:${port}" -f "$known_hosts" &>/dev/null < /dev/null || true
    fi

    echo "$scan_out" | _app_file_op "$app" "$known_hosts" 'umask 077; cat >> "$1" && chmod 600 "$1"'

    success "Fingerprint of ${host}:${port} trusted for '${app}'"
    echo ""
    echo -e "${BOLD}Fingerprints added:${NC}"
    echo "$scan_out" | awk '{print "  " $0}' | cut -c1-80
    echo ""

    # Show the deploy key as a reminder
    local kf="${home}/.ssh/id_ed25519.pub"
    if [[ -f "$kf" ]]; then
        echo -e "${BOLD}Deploy Key${NC} (add this to your Git server):"
        echo -e "  ${CYAN}$(app_read "$app" "$kf" || true)${NC}"
        echo ""
    fi

    # If non-standard port, write/update SSH config entry
    if [[ "$port" != "22" ]]; then
        local ssh_cfg="${home}/.ssh/config"
        # The file without this host's block, if it had one, then the block:
        # read and written whole (app_write takes all of it before it writes).
        {
            if [[ -f "$ssh_cfg" ]]; then
                app_read "$app" "$ssh_cfg" | awk -v h="$host" '
                    /^Host / { in_block = ($2 == h) }
                    !in_block { print }
                ' || true
            fi
            cat <<SSHCFG

Host ${host}
    HostName ${host}
    Port ${port}
    IdentityFile ${home}/.ssh/id_ed25519
    StrictHostKeyChecking accept-new
SSHCFG
        } | app_write "$app" "$ssh_cfg" 600
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
    if [[ "$(app_get "$app" runtime)" == "node" ]]; then
        echo "  Verified by Cipi itself (no cipi/agent needed for Node apps)."
    else
        echo "  Requires: composer require cipi/agent"
    fi
    echo ""
}
