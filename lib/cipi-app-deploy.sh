#!/bin/bash
#############################################
# Cipi — Automatic deploy wrapper (app user)
#
# Runs from the app's own crontab when a webhook drops ~/.deploy-trigger.
# Wraps `dep deploy` so the automatic path produces the same readable log as
# `cipi deploy`: a start/end banner naming the trigger, the branch, the
# release and the duration, and a wall-clock timestamp on every line.
# Raw Deployer output alone had no dates and no release markers, so a deploy
# that failed overnight could not be reconstructed afterwards.
#
# Every run is also recorded in the root-owned deploy audit ledger by the
# Deployer recipe itself (cipi-deploy-audit), like any other deploy.
#
# Usage: cipi-app-deploy <app> <php_version> [trigger]
#############################################
set -uo pipefail

APP="${1:-}"; PHP_VER="${2:-}"; TRIGGER="${3:-webhook}"
[[ -z "$APP" || -z "$PHP_VER" ]] && { echo "Usage: cipi-app-deploy <app> <php_version> [trigger]" >&2; exit 2; }

# Refuse to act on anything but the invoking user's own app: this runs from a
# user crontab, so it must never be a lever to touch another app's home.
[[ "$APP" =~ ^[a-z][a-z0-9]{2,31}$ ]]   || { echo "cipi-app-deploy: invalid app name" >&2; exit 2; }
[[ "$PHP_VER" =~ ^8\.[0-9]$ ]]          || { echo "cipi-app-deploy: invalid php version" >&2; exit 2; }
[[ "$TRIGGER" =~ ^[a-z-]{1,20}$ ]]      || TRIGGER="webhook"
if [[ "$(id -un)" != "$APP" && "$(id -u)" -ne 0 ]]; then
    echo "cipi-app-deploy: must run as '${APP}' (or root)" >&2
    exit 2
fi

HOME_DIR="/home/${APP}"
DEPLOY_FILE="${HOME_DIR}/.deployer/deploy.php"
# The deploy log is /var/log/cipi-apps/<app>/deploy.log since 5.9.0: a file of
# this user in a directory of root's, so `cipi deploy` (root) can append to the
# same log without following anything this user could put in its place.
# ~/logs/deploy.log is a symlink to it. Where that file is not there yet, the
# old place.
LOG="/var/log/cipi-apps/${APP}/deploy.log"
[[ -f "$LOG" && ! -L "$LOG" && -w "$LOG" ]] || LOG="${HOME_DIR}/logs/deploy.log"

# ── One deploy at a time: a push that arrives meanwhile waits its turn ──
# The cron moves ~/.deploy-trigger and starts this every minute, also while a
# deploy is still running. Deployer refused the second run ("Deploy locked"),
# it was reported as a failed deploy, and the push it was for never deployed.
# Now a trigger that finds a deploy in flight — another automatic one (before,
# during or after Deployer), or `cipi deploy` / the panel while Deployer runs —
# goes back in the queue, and deploys when that one is over. Several pushes in
# the meantime make one deploy, of the branch as it is then.
RUN_DIR="${HOME_DIR}/.deploy-running"
_requeue() {
    if [[ -f "${HOME_DIR}/.deploy-trigger.run" && ! -L "${HOME_DIR}/.deploy-trigger.run" ]]; then
        # Never over a newer trigger: that one is the queue now.
        mv -n "${HOME_DIR}/.deploy-trigger.run" "${HOME_DIR}/.deploy-trigger" 2>/dev/null || true
        rm -f "${HOME_DIR}/.deploy-trigger.run" 2>/dev/null || true
    elif [[ ! -e "${HOME_DIR}/.deploy-trigger" ]]; then
        : > "${HOME_DIR}/.deploy-trigger" 2>/dev/null || true
    fi
}
# Deployer at work on this app, whoever started it (it always runs as the app user).
_dep_alive() {
    pgrep -u "$APP" -f -- "dep (deploy|rollback) -f ${DEPLOY_FILE}" >/dev/null 2>&1
}
_wrapper_alive() {   # the run that holds RUN_DIR is still going
    local p; p=$(head -c 20 "${RUN_DIR}/pid" 2>/dev/null || true)
    [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null \
        && tr '\0' ' ' < "/proc/${p}/cmdline" 2>/dev/null | grep -q "cipi-app-deploy ${APP} "
}
if ! mkdir "$RUN_DIR" 2>/dev/null; then
    if _wrapper_alive; then _requeue; exit 0; fi
    # Left behind by a run that was killed: nothing holds it any more.
    rm -f "${RUN_DIR}/pid" 2>/dev/null || true
    rmdir "$RUN_DIR" 2>/dev/null || true
    mkdir "$RUN_DIR" 2>/dev/null || { _requeue; exit 0; }
fi
echo "$$" > "${RUN_DIR}/pid"
trap 'rm -f "${RUN_DIR}/pid" 2>/dev/null; rmdir "$RUN_DIR" 2>/dev/null' EXIT
if _dep_alive; then _requeue; exit 0; fi

# A lock with no Deployer alive was left by a deploy that was interrupted (a
# reboot, a kill): a deploy that fails releases its own (deploy:failed →
# deploy:unlock). Nobody has to remove it by hand before the next push.
STALE_LOCK=""
if [[ -f "${HOME_DIR}/.dep/deploy.lock" && ! -L "${HOME_DIR}/.dep/deploy.lock" ]] && ! _dep_alive; then
    STALE_LOCK=$(head -c 120 "${HOME_DIR}/.dep/deploy.lock" 2>/dev/null | tr -cd '[:alnum:]._@ -' || true)
    rm -f "${HOME_DIR}/.dep/deploy.lock" 2>/dev/null || STALE_LOCK=""
fi

# The cron moves ~/.deploy-trigger here before calling us. Whoever wrote it
# (the Git webhook endpoint of cipi/agent, its MCP deploy tool, …) may say who
# asked for the deploy, as JSON or as KEY=VALUE lines:
#   {"source":"mcp","actor":"jane@example.com","ip":"203.0.113.9","ref":"main","request_id":"…"}
# These are claims from the app's own code, not facts: they are exported for
# cipi-deploy-audit, which records them under "claimed", next to what root
# established on its own. An empty or unreadable file is just a plain trigger.
TRIGGER_META="${HOME_DIR}/.deploy-trigger.run"
if [[ -f "$TRIGGER_META" && ! -L "$TRIGGER_META" ]]; then
    meta=$(head -c 4096 "$TRIGGER_META" 2>/dev/null || true)
    rm -f "$TRIGGER_META" 2>/dev/null || true
    _meta_get() {
        local k="$1" v=""
        if [[ "$meta" =~ ^[[:space:]]*\{ ]] && command -v jq >/dev/null 2>&1; then
            v=$(jq -r --arg k "$k" '.[$k] // empty | tostring' <<< "$meta" 2>/dev/null || true)
        else
            v=$(sed -n "s/^[[:space:]]*${k}[[:space:]]*=[[:space:]]*//p" <<< "$meta" | head -1)
        fi
        printf '%s' "$v" | tr -cd 'A-Za-z0-9._@:/+=, -' | cut -c1-128
    }
    m_source=$(_meta_get source)
    [[ -n "$m_source" ]] && export CIPI_DEPLOY_SOURCE="$m_source"
    m_val=$(_meta_get actor);      [[ -n "$m_val" ]] && export CIPI_DEPLOY_ACTOR="$m_val"
    m_val=$(_meta_get ip);         [[ -n "$m_val" ]] && export CIPI_DEPLOY_IP="$m_val"
    m_val=$(_meta_get ref);        [[ -n "$m_val" ]] && export CIPI_DEPLOY_REF="$m_val"
    m_val=$(_meta_get request_id); [[ -n "$m_val" ]] && export CIPI_DEPLOY_REQUEST_ID="$m_val"
    # A recognizable source names the trigger in the deploy log (trigger=mcp).
    m_source=$(printf '%s' "$m_source" | tr '[:upper:]' '[:lower:]')
    [[ "$m_source" =~ ^[a-z-]{1,20}$ ]] && TRIGGER="$m_source"
    unset -f _meta_get
fi
export CIPI_DEPLOY_TRIGGER="$TRIGGER"

[[ -f "$DEPLOY_FILE" ]] || { echo "cipi-app-deploy: ${DEPLOY_FILE} not found" >&2; exit 2; }
mkdir -p "${HOME_DIR}/logs" 2>/dev/null || true
touch "$LOG" 2>/dev/null || true

# ── A commit that failed does not deploy again by itself ─────
# When an automatic deploy fails with the code in hand (its release has a
# REVISION), that commit is written to ~/.dep/cipi-paused-commit, and the
# automatic deploys of the same commit stop there: a redelivered webhook, a
# cipi/agent retry, do not build it again. A new commit on the branch deploys
# as usual and clears it, and so do a deploy by hand (`cipi deploy`, the
# panel) that succeeds and `cipi deploy <app> --unlock`. Nothing to unlock
# to push a fix.
PAUSE_FILE="${HOME_DIR}/.dep/cipi-paused-commit"
# The commit Deployer would deploy now: the head of the app's branch, asked
# of the remote with the deploy key, as Deployer does. Empty when unknown.
_branch_head() {
    local repo branch sshc
    repo=$(sed -n "s/^set('repository', '\(.*\)');[[:space:]]*\$/\1/p" "$DEPLOY_FILE" 2>/dev/null | head -n 1)
    branch=$(sed -n "s/^set('branch', '\(.*\)');[[:space:]]*\$/\1/p" "$DEPLOY_FILE" 2>/dev/null | head -n 1)
    sshc=$(sed -n "s/^set('git_ssh_command', '\(.*\)');[[:space:]]*\$/\1/p" "$DEPLOY_FILE" 2>/dev/null | head -n 1)
    [[ -n "$repo" && -n "$branch" ]] || return 0
    GIT_SSH_COMMAND="${sshc:-ssh} -o BatchMode=yes" GIT_TERMINAL_PROMPT=0 \
        timeout 30 git ls-remote -- "$repo" "refs/heads/${branch}" 2>/dev/null | awk 'NR == 1 { print $1 }'
}
PAUSED=""
if [[ -f "$PAUSE_FILE" && ! -L "$PAUSE_FILE" ]]; then
    PAUSED=$(head -n 1 "$PAUSE_FILE" 2>/dev/null | tr -cd '0-9a-f')
fi
if [[ -n "$PAUSED" ]]; then
    HEAD_NOW=$(_branch_head || true)
    # A remote that does not answer is not a reason to hold a push back.
    if [[ "$HEAD_NOW" == "$PAUSED" ]]; then
        printf '[%(%Y-%m-%d %H:%M:%S)T] ===== deploy skipped  app=%s trigger=%s commit=%s — it failed last time: push a fix, or deploy it by hand (cipi deploy %s) =====\n\n' \
            -1 "$APP" "$TRIGGER" "${PAUSED:0:12}" "$APP" >> "$LOG" 2>/dev/null || true
        exit 0
    fi
fi

_release() {
    local target
    [[ -L "${HOME_DIR}/current" ]] || { echo ""; return 0; }
    target=$(readlink "${HOME_DIR}/current" 2>/dev/null || true)
    [[ -z "$target" ]] && { echo ""; return 0; }
    basename "$target"
}

BRANCH=""
if [[ -d "${HOME_DIR}/current/.git" ]]; then
    BRANCH=$(git -C "${HOME_DIR}/current" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
fi

REL_BEFORE=$(_release)
T0=$SECONDS

{
    printf '[%(%Y-%m-%d %H:%M:%S)T] ===== deploy start  app=%s trigger=%s branch=%s from-release=%s =====\n' \
        -1 "$APP" "$TRIGGER" "${BRANCH:-?}" "${REL_BEFORE:-none}"
    [[ -n "$STALE_LOCK" ]] && printf '[%(%Y-%m-%d %H:%M:%S)T] removed the lock left by an interrupted deploy (%s)\n' -1 "$STALE_LOCK"
} >> "$LOG" 2>/dev/null || true

# Which release this run makes: the commit of a release that fails is paused.
LATEST_BEFORE=$(head -c 20 "${HOME_DIR}/.dep/latest_release" 2>/dev/null | tr -cd '0-9')
DEP_MARK=$(wc -l < "$LOG" 2>/dev/null || echo 0)

RC=0
cd "$HOME_DIR" || exit 2
"/usr/bin/php${PHP_VER}" /usr/local/bin/dep deploy -f "$DEPLOY_FILE" 2>&1 \
    | while IFS= read -r line; do
          printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$line"
      done >> "$LOG"
RC=${PIPESTATUS[0]}

# Refused because another deploy took the lock between the check above and
# Deployer's own (`cipi deploy` or the panel, that very second): not a failure
# of this push, which goes back in the queue.
LOCK_REFUSED=false
if [[ $RC -ne 0 ]] && tail -n +"$((DEP_MARK + 1))" "$LOG" 2>/dev/null | grep -q 'Deploy locked by'; then
    LOCK_REFUSED=true
fi

PAUSED_NOW=""
if [[ $RC -eq 0 ]]; then
    rm -f "$PAUSE_FILE" 2>/dev/null || true
elif [[ "$LOCK_REFUSED" != true ]]; then
    LATEST_AFTER=$(head -c 20 "${HOME_DIR}/.dep/latest_release" 2>/dev/null | tr -cd '0-9')
    if [[ -n "$LATEST_AFTER" && "$LATEST_AFTER" != "$LATEST_BEFORE" \
          && -f "${HOME_DIR}/releases/${LATEST_AFTER}/REVISION" && ! -L "${HOME_DIR}/releases/${LATEST_AFTER}/REVISION" ]]; then
        PAUSED_NOW=$(head -n 1 "${HOME_DIR}/releases/${LATEST_AFTER}/REVISION" 2>/dev/null | tr -cd '0-9a-f')
        if [[ ${#PAUSED_NOW} -ge 40 && ! -L "$PAUSE_FILE" ]]; then
            printf '%s\n' "$PAUSED_NOW" > "$PAUSE_FILE" 2>/dev/null || PAUSED_NOW=""
        else
            PAUSED_NOW=""
        fi
    fi
fi

REL_AFTER=$(_release)
SECS=$(( SECONDS - T0 ))
RESULT="OK"; [[ $RC -eq 0 ]] || RESULT="FAILED"

{
    printf '[%(%Y-%m-%d %H:%M:%S)T] ===== deploy %s  app=%s release=%s duration=%ss exit=%s =====\n\n' \
        -1 "$RESULT" "$APP" "${REL_AFTER:-?}" "$SECS" "$RC"
} >> "$LOG" 2>/dev/null || true

# What was actually published — the part worth reading in the alert.
COMMIT=""
REL_DIR="${HOME_DIR}/releases/${REL_AFTER}"
[[ -d "${REL_DIR}/.git" ]] || REL_DIR="${HOME_DIR}/current"
if [[ -d "${REL_DIR}/.git" ]]; then
    COMMIT=$(git -C "$REL_DIR" log -1 --format='%h — %s%nAuthor: %an%nCommitted: %ad' \
        --date=format:'%Y-%m-%d %H:%M' 2>/dev/null || true)
fi

DETAIL="Trigger: ${TRIGGER}
Branch: ${BRANCH:-?}
Release: ${REL_BEFORE:-none} -> ${REL_AFTER:-?}${COMMIT:+
Commit: ${COMMIT}}
Duration: ${SECS}s
Log: ${LOG}"

if [[ "$LOCK_REFUSED" == true ]]; then
    printf '[%(%Y-%m-%d %H:%M:%S)T] another deploy holds the lock — this push is queued again\n\n' -1 >> "$LOG" 2>/dev/null || true
    _requeue
    exit 0
fi
if [[ $RC -ne 0 ]]; then
    if [[ -n "$PAUSED_NOW" ]]; then
        printf '[%(%Y-%m-%d %H:%M:%S)T] automatic deploys of %s paused: a new push deploys, or by hand: cipi deploy %s\n\n' \
            -1 "${PAUSED_NOW:0:12}" "$APP" >> "$LOG" 2>/dev/null || true
        DETAIL="${DETAIL}
Automatic deploys: paused for commit ${PAUSED_NOW:0:12} — the next push deploys as usual; to retry this commit: cipi deploy ${APP} (or the panel)"
    fi
    sudo /usr/local/bin/cipi-app-notify "$APP" deploy "$RC" "$LOG" "$DETAIL" 2>/dev/null || true
    exit "$RC"
fi

# Reconcile the server with the cipi.yml shipped in this release, but only when
# root has explicitly opted this app in (`cipi yml auto <app> on`), which is
# also what creates the single narrowly scoped sudoers rule below. Without that
# rule the app user cannot run this at all.
#
# Ask sudo whether the rule is there instead of looking for the drop-in file:
# /etc/sudoers.d is 0750 root:root on Debian and Ubuntu, so to the app user
# `test -f /etc/sudoers.d/cipi-<app>-yml` is always false, and before 5.6.4 a
# webhook deploy never applied cipi.yml even with auto-apply on.
YML_LINE=""
if sudo -n -l /usr/local/bin/cipi yml apply "$APP" --yes --auto >/dev/null 2>&1; then
    {
        printf '[%(%Y-%m-%d %H:%M:%S)T] ===== cipi.yml apply =====\n' -1
    } >> "$LOG" 2>/dev/null || true
    YML_MARK=$(wc -l < "$LOG" 2>/dev/null || echo 0)
    YML_RC=0
    sudo -n /usr/local/bin/cipi yml apply "$APP" --yes --auto >> "$LOG" 2>&1 || YML_RC=$?
    if [[ $YML_RC -ne 0 ]]; then
        printf '[%(%Y-%m-%d %H:%M:%S)T] cipi.yml apply failed — see above\n' -1 >> "$LOG" 2>/dev/null || true
    fi
    YML_RAW=$(tail -n +"$((YML_MARK + 1))" "$LOG" 2>/dev/null | grep 'cipi.yml-result:' | tail -1 | sed 's/.*cipi.yml-result: //' || true)
    case "$YML_RAW" in
        applied=*) YML_LINE="applied ${YML_RAW#applied=} change(s)" ;;
        unchanged) YML_LINE="already matches" ;;
        no-file)   YML_LINE="no cipi.yml in this release" ;;
        blocked)   YML_LINE="NOT applied — the plan was blocked (see the deploy log)" ;;
        invalid)   YML_LINE="NOT applied — cipi.yml failed validation (see the deploy log)" ;;
        disabled)  YML_LINE="NOT applied — auto-apply is not enabled" ;;
        failed=*)  YML_LINE="NOT applied cleanly (${YML_RAW}) — see the deploy log" ;;
        *)
            if [[ $YML_RC -ne 0 ]]; then
                YML_LINE="NOT applied — see the deploy log"
            else
                YML_LINE="ok"
            fi
            ;;
    esac
fi

# Allowlisted post-deploy steps from cipi.yml (npm run, artisan, …). The
# summary is read back from the lines this run appended: older deploys share
# the file, and their summary must not stand in for this one.
POST_MARK=$(wc -l < "$LOG" 2>/dev/null || echo 0)
POST_RC=0
if [[ -x /usr/local/bin/cipi-app-post-deploy ]]; then
    /usr/local/bin/cipi-app-post-deploy "$APP" "$PHP_VER" "$LOG" || POST_RC=$?
    if [[ $POST_RC -eq 2 ]]; then
        printf '[%(%Y-%m-%d %H:%M:%S)T] post-deploy steps not run — the runner could not start, see above\n' -1 >> "$LOG" 2>/dev/null || true
    elif [[ $POST_RC -ne 0 ]]; then
        printf '[%(%Y-%m-%d %H:%M:%S)T] post-deploy steps failed — see above\n' -1 >> "$LOG" 2>/dev/null || true
    fi
fi

# Did the release that just went live actually survive? An automatic deploy has
# nobody watching it, so this is the only thing standing between a broken push
# and finding out from a customer. It never changes the deploy's own result —
# the code is published either way — but a failure alerts immediately instead
# of waiting for the periodic checker's three-strike debounce, and rolls the
# release back when the app opted into that.
{
    printf '[%(%Y-%m-%d %H:%M:%S)T] ===== post-deploy healthcheck =====\n' -1
} >> "$LOG" 2>/dev/null || true
HRC=0
sudo /usr/local/bin/cipi health postdeploy "$APP" --auto >> "$LOG" 2>&1 || HRC=$?

case "$HRC" in
    0) HEALTH_LINE="passed" ;;
    2) HEALTH_LINE="not configured (cipi health set ${APP})" ;;
    *) HEALTH_LINE="FAILED — a separate alert has been sent" ;;
esac

# Sent last, so "deploy succeeded" can say whether the app actually answers.
# Announcing success while the site returns 500 would be worse than silence.
POST_LINE=$(tail -n +"$((POST_MARK + 1))" "$LOG" 2>/dev/null | grep 'post-deploy summary:' | tail -1 | sed 's/.*post-deploy summary: //; s/ (exit=.*//')
if [[ -z "$POST_LINE" ]]; then
    if [[ $POST_RC -ne 0 ]]; then POST_LINE="see deploy log"; else POST_LINE="none declared"; fi
fi

sudo /usr/local/bin/cipi-app-notify "$APP" deploy-ok 0 "$LOG" \
    "${DETAIL}
Post-deploy: ${POST_LINE}
${YML_LINE:+cipi.yml: ${YML_LINE}
}Healthcheck: ${HEALTH_LINE}" 2>/dev/null || true

# Integrity manifest for cipi scan: hash of this release (symlinks not followed).
# Root-only writer, reached through the per-app sudoers entry — the manifest
# lives outside /home/<app> so the app user cannot rewrite its own baseline.
if [[ -x /usr/local/bin/cipi-scan-manifest ]]; then
    sudo /usr/local/bin/cipi-scan-manifest "$APP" >/dev/null 2>&1 || true
fi

exit 0
