#!/bin/bash
#############################################
# Cipi — Deploy audit ledger (root)
#
# Called by the Deployer recipe of every app (runLocally → sudo) when a release
# is published, a deploy fails, or a release is rolled back. Whatever started
# `dep` — `cipi deploy`, the Git webhook, cipi/agent (webhook or MCP), the
# panel, or someone running `dep deploy` by hand as the app user — ends up
# here, because the recipe is the one thing all of those share.
#
# Nothing the caller says is taken at face value. Root reads the facts itself:
#   * the release `current` points at, its commit (Deployer's REVISION) and
#     Deployer's own releases_log entry;
#   * the process chain above `dep` from /proc — who ran it (cron, php-fpm, a
#     queue worker, an SSH session, `cipi deploy` as root, the panel), the
#     audit login uid (set by PAM at login, not changeable by the user) and the
#     SSH client address.
# What an unprivileged process can only *claim* (CIPI_DEPLOY_SOURCE/ACTOR/…,
# e.g. from the webhook payload) is kept apart under "claimed".
#
# Records are JSON lines in /var/log/cipi/deploys.jsonl (root-only). Each one
# carries the SHA-256 of the line before it, so an edit or a deletion in the
# middle breaks the chain (`cipi compliance deploys` verifies it), and each is
# also sent to syslog so remote log forwarding keeps a copy off the server.
#
# Usage: cipi-deploy-audit <app> <published|failed|rollback>
#############################################
set -uo pipefail
umask 077
export LC_ALL=C

APP="${1:-}"; EVENT="${2:-}"
[[ "$APP" =~ ^[a-z][a-z0-9]{2,31}$ ]] || { echo "cipi-deploy-audit: invalid app name" >&2; exit 2; }
case "$EVENT" in published|failed|rollback) ;; *) echo "cipi-deploy-audit: invalid event" >&2; exit 2 ;; esac
[[ "$(id -u)" -eq 0 ]] || { echo "cipi-deploy-audit: must run as root" >&2; exit 2; }
# Through sudo, only the app itself (or root) may write records for it.
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "$APP" && "$SUDO_USER" != "root" ]]; then
    echo "cipi-deploy-audit: ${SUDO_USER} cannot record deploys for ${APP}" >&2
    exit 2
fi
id "$APP" &>/dev/null || { echo "cipi-deploy-audit: no such user ${APP}" >&2; exit 2; }

HOME_DIR="/home/${APP}"
LOG_DIR="${CIPI_LOG:-/var/log/cipi}"
LEDGER="${LOG_DIR}/deploys.jsonl"
mkdir -p "$LOG_DIR" 2>/dev/null || true

# Printable, bounded, JSON- and log-safe.
_clean() { printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9._@:/+=, -' | cut -c1-"${2:-128}"; }

# ── facts about the release ──────────────────────────────────
release=""
if [[ -L "${HOME_DIR}/current" ]]; then
    release=$(basename "$(readlink "${HOME_DIR}/current" 2>/dev/null)" 2>/dev/null || true)
fi
commit=""
if [[ -n "$release" && -f "${HOME_DIR}/releases/${release}/REVISION" ]]; then
    commit=$(head -c 40 "${HOME_DIR}/releases/${release}/REVISION" 2>/dev/null | tr -cd '0-9a-f')
elif [[ -d "${HOME_DIR}/htdocs/.git" ]]; then
    commit=$(git -c safe.directory='*' -C "${HOME_DIR}/htdocs" rev-parse HEAD 2>/dev/null | tr -cd '0-9a-f' || true)
fi

# Deployer's own record of the run that just happened: on a failed deploy this
# is the release that was being built (it never became `current`).
dep_release="" dep_user="" dep_target="" dep_created=""
if [[ -f "${HOME_DIR}/.dep/releases_log" ]] && command -v jq >/dev/null 2>&1; then
    IFS=$'\t' read -r dep_release dep_user dep_target dep_created < <(
        tail -n 1 "${HOME_DIR}/.dep/releases_log" 2>/dev/null \
            | jq -r '[.release_name // "", .user // "", .target // "", .created_at // ""] | map(tostring) | @tsv' 2>/dev/null
    ) || true
fi
dep_release=$(_clean "$dep_release" 32); dep_user=$(_clean "$dep_user" 64)
dep_target=$(_clean "$dep_target" 128); dep_created=$(_clean "$dep_created" 40)

branch=""
if [[ -f /opt/cipi/lib/vault.sh && -f /etc/cipi/apps.json ]]; then
    # shellcheck source=/dev/null
    branch=$( (CIPI_CONFIG=/etc/cipi; source /opt/cipi/lib/vault.sh 2>/dev/null \
        && vault_read apps.json 2>/dev/null | jq -r --arg a "$APP" '.[$a].branch // empty') 2>/dev/null || true)
fi
branch=$(_clean "$branch" 128)

# ── who started it: walk the process chain above us ──────────
#
# The nearest recognizable process decides the origin:
#   cipi-cli   a root process carrying CIPI_DEPLOY_TRIGGER (`cipi deploy`,
#              rollback, auto-rollback) — "panel" when www-data started it
#   root-shell root ran `sudo -u <app> dep …` itself
#   webhook    cipi-app-deploy (the ~/.deploy-trigger cron: Git webhook, cipi/agent)
#   app-web    PHP-FPM — the app ran dep inside a web request
#   app-queue  a queue worker / Horizon
#   ssh        an SSH session of the app user
#   cron       any other cron job
# Daemons further up (cron, sshd, systemd run as root) say nothing about who
# asked, so they never override a nearer answer.
origin="unknown" trigger="" operator="" ssh_ip="" chain="" nr_trigger=""
claimed_source="" claimed_actor="" claimed_ip="" claimed_ref="" claimed_request=""
root_seen=false www_seen=false

_env_of() { tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null; }

pid=$PPID depth=0
# Our own sudo is not evidence of anything: start above it.
if [[ "$(cat "/proc/${pid}/comm" 2>/dev/null)" == "sudo" ]]; then
    pid=$(awk '/^PPid:/ { print $2 }' "/proc/${pid}/status" 2>/dev/null || echo 1)
fi
while [[ -n "$pid" && "$pid" -gt 1 && $depth -lt 40 ]]; do
    depth=$((depth + 1))
    [[ -r "/proc/${pid}/status" ]] || break
    comm=$(cat "/proc/${pid}/comm" 2>/dev/null || true)
    ruid=$(awk '/^Uid:/ { print $2 }' "/proc/${pid}/status" 2>/dev/null)
    ppid=$(awk '/^PPid:/ { print $2 }' "/proc/${pid}/status" 2>/dev/null)
    cmd=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | cut -c1-300)
    luid=$(cat "/proc/${pid}/loginuid" 2>/dev/null || echo 4294967295)
    uname=$(getent passwd "$ruid" 2>/dev/null | cut -d: -f1); uname="${uname:-$ruid}"
    chain="${chain:+${chain} < }$(_clean "$comm" 32)(${uname})"
    envs=$(_env_of "$pid")

    if [[ -z "$ssh_ip" ]]; then
        ssh_ip=$(sed -n 's/^SSH_CONNECTION=\([^ ]*\) .*/\1/p' <<< "$envs" | head -1)
    fi
    if [[ -z "$operator" && "$luid" != "4294967295" ]]; then
        operator=$(getent passwd "$luid" 2>/dev/null | cut -d: -f1); operator="${operator:-uid:${luid}}"
    fi
    [[ "$uname" == "www-data" ]] && www_seen=true

    if [[ "$ruid" == "0" ]]; then
        if [[ "$origin" == "unknown" ]]; then
            # Root's environment is trustworthy: `cipi deploy` exports its
            # trigger before handing over to the app user.
            t=$(sed -n 's/^CIPI_DEPLOY_TRIGGER=//p' <<< "$envs" | head -1)
            if [[ -n "$t" ]]; then
                origin="cipi-cli"; trigger=$(_clean "$t" 24)
            elif [[ "$comm" == sudo || "$comm" == su || "$comm" == runuser ]]; then
                origin="root-shell"
            fi
        fi
        root_seen=true
    elif [[ "$root_seen" == false ]]; then
        # Below the first root process: an unprivileged process's *claims*,
        # recorded but kept apart from what root established.
        [[ -z "$nr_trigger" ]] && nr_trigger=$(sed -n 's/^CIPI_DEPLOY_TRIGGER=//p' <<< "$envs" | head -1)
        for kv in SOURCE ACTOR IP REF REQUEST_ID; do
            v=$(sed -n "s/^CIPI_DEPLOY_${kv}=//p" <<< "$envs" | head -1)
            [[ -z "$v" ]] && continue
            case "$kv" in
                SOURCE)     [[ -z "$claimed_source"  ]] && claimed_source=$(_clean "$v" 32) ;;
                ACTOR)      [[ -z "$claimed_actor"   ]] && claimed_actor=$(_clean "$v" 128) ;;
                IP)         [[ -z "$claimed_ip"      ]] && claimed_ip=$(_clean "$v" 64) ;;
                REF)        [[ -z "$claimed_ref"     ]] && claimed_ref=$(_clean "$v" 128) ;;
                REQUEST_ID) [[ -z "$claimed_request" ]] && claimed_request=$(_clean "$v" 64) ;;
            esac
        done
        if [[ "$origin" == "unknown" ]]; then
            case "$comm $cmd" in
                *cipi-app-deploy*)      origin="webhook"; trigger=$(_clean "${nr_trigger:-webhook}" 24) ;;
                php-fpm*)               origin="app-web" ;;
                *queue:work*|*horizon*) origin="app-queue" ;;
                sshd*)                  origin="ssh" ;;
                cron*|CRON*)            origin="cron" ;;
            esac
        fi
    fi
    [[ "$ppid" =~ ^[0-9]+$ ]] || break
    pid="$ppid"
done
# `cipi deploy` launched by the panel (API queue worker / GUI, both www-data).
[[ "$origin" == "cipi-cli" && "$www_seen" == true ]] && origin="panel"
ssh_ip=$(_clean "$ssh_ip" 64); operator=$(_clean "$operator" 64); chain=$(_clean "$chain" 600)

# ── append, chained ──────────────────────────────────────────
exec 9>>"$LEDGER" || { echo "cipi-deploy-audit: cannot open ${LEDGER}" >&2; exit 1; }
flock -w 10 9 || { echo "cipi-deploy-audit: ledger is locked" >&2; exit 1; }
chown root:root "$LEDGER" 2>/dev/null || true
chmod 600 "$LEDGER" 2>/dev/null || true

last=$(tail -n 1 "$LEDGER" 2>/dev/null || true)
prev="" seq=1
if [[ -n "$last" ]]; then
    prev=$(printf '%s' "$last" | sha256sum | awk '{print $1}')
    seq=$(( $(jq -r '.seq // 0' <<< "$last" 2>/dev/null || echo 0) + 1 ))
fi

# The recipe hooks cannot fire twice for one release, but anyone allowed to run
# this can call it again: a repeat of the app's last publish/rollback for the
# same release is not a new deploy.
if [[ "$EVENT" != "failed" && -n "$release" ]]; then
    last_app=$(grep -F "\"app\":\"${APP}\"" "$LEDGER" 2>/dev/null | grep -E '"event":"(published|rollback)"' | tail -n 1)
    if [[ -n "$last_app" && "$(jq -r '.release' <<< "$last_app" 2>/dev/null)" == "$release" ]]; then
        exit 0
    fi
fi

line=$(jq -nc \
    --argjson seq "$seq" \
    --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg host "$(hostname 2>/dev/null)" \
    --arg app "$APP" --arg event "$EVENT" \
    --arg release "$release" --arg commit "$commit" --arg branch "$branch" \
    --arg dep_release "$dep_release" --arg dep_user "$dep_user" \
    --arg dep_target "$dep_target" --arg dep_created "$dep_created" \
    --arg origin "$origin" --arg trigger "$trigger" --arg operator "$operator" \
    --arg ip "$ssh_ip" --arg chain "$chain" \
    --arg c_source "$claimed_source" --arg c_actor "$claimed_actor" --arg c_ip "$claimed_ip" \
    --arg c_ref "$claimed_ref" --arg c_request "$claimed_request" \
    --arg prev "$prev" '
    {seq: $seq, ts: $ts, host: $host, app: $app, event: $event,
     release: $release, commit: $commit, branch: $branch,
     deployer: {release: $dep_release, user: $dep_user, target: $dep_target, created_at: $dep_created},
     origin: $origin, trigger: $trigger, operator: $operator, ip: $ip, chain: $chain,
     claimed: ({source: $c_source, actor: $c_actor, ip: $c_ip, ref: $c_ref, request_id: $c_request}
               | with_entries(select(.value != ""))),
     prev: $prev}')
[[ -n "$line" ]] || { echo "cipi-deploy-audit: could not build the record" >&2; exit 1; }

printf '%s\n' "$line" >&9
logger -t cipi-deploy -p user.notice -- "$line" 2>/dev/null || true
exit 0
