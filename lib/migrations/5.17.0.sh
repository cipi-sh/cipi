#!/bin/bash
#############################################
# Cipi Migration 5.17.0
#
#  1. logrotate. Ubuntu's /var/log is root:syslog 0775 wherever rsyslog is
#     installed, and logrotate skips a log in a directory a group other than
#     root can write unless the rule says who to rotate as ("su"). Ubuntu's
#     /etc/logrotate.conf says it for every rule it includes, so the nightly
#     run rotated Cipi's logs all along; a rule read on its own did not have
#     the line, and `cipi pending` — which reads Cipi's rules that way —
#     reported auth.log, fail2ban.log and ufw.log as skipped, with a hint
#     (cipi app fix-permissions) that changed nothing. Every block of a
#     cipi-* rule that names a log directly in /var/log gets "su root adm"
#     (logrotate_cipi_su in common.sh). Blocks that have a su line, and the
#     per-app rules, are not touched.
#
#  2. Deploys. recipe/laravel.php's own `deploy` task runs
#     artisan:storage:link, artisan:optimize and artisan:migrate after the
#     vendors, and so do Cipi's hooks: every deploy did each of them twice,
#     and a step turned off with `cipi app deploy-config` (--no-migrate) still
#     ran once. deploy.php of every Laravel and Octane app gets the flow of
#     lib/deployer/flow.php: after the vendors only the hooks run
#     (deployer_flow_ensure_hook). A deploy.php that defines its own `deploy`
#     task, or whose three hooks are not where Cipi writes them, is left as
#     it is and named.
#
# Nothing restarts, nothing is deployed. The page cache (cipi cache), the
# notification time zone and server name are off until someone turns them on.
#############################################
set -euo pipefail

export CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
export CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
export CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"

echo "Migration 5.17.0 — logrotate rules, one pass per deploy step..."

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"

# ── 1. logrotate ─────────────────────────────────────────────
if declare -f logrotate_cipi_su >/dev/null 2>&1; then
    fixed=$(logrotate_cipi_su | paste -sd' ' - || true)
    if [[ -n "$fixed" ]]; then
        echo "  logrotate: \"su root adm\" added to ${fixed}"
        log_action "LOGROTATE: su root adm added to ${fixed}" 2>/dev/null || true
    else
        echo "  logrotate: Cipi's rules need no change"
    fi
    if declare -f logrotate_cipi_check >/dev/null 2>&1 && ! lr_err=$(logrotate_cipi_check); then
        echo "  WARNING: logrotate still reports a problem with a Cipi rule:"
        printf '%s\n' "$lr_err" | sed 's/^/    /'
    fi
fi

# ── 2. deploy flow ───────────────────────────────────────────
if [[ ! -f "${CIPI_CONFIG}/apps.json" ]]; then
    echo "  no apps"
    echo "Migration 5.17.0 complete"
    exit 0
fi

n_flow=0
while IFS= read -r u; do
    [[ "$u" =~ ^[a-z][a-z0-9]{2,31}$ ]] || continue
    id "$u" &>/dev/null || continue
    [[ "$(app_get "$u" custom 2>/dev/null || true)" == "true" ]] && continue
    [[ "$(app_get "$u" runtime 2>/dev/null || true)" == "node" ]] && continue
    df="/home/${u}/.deployer/deploy.php"
    [[ -f "$df" ]] || continue

    before_sum=$(app_read "$u" "$df" 2>/dev/null | md5sum || true)
    kr=$(app_get "$u" keep_releases 2>/dev/null || true); [[ "$kr" =~ ^[0-9]+$ ]] || kr=5
    rc=0
    deployer_flow_ensure_hook "$u" || rc=$?
    case "$rc" in
        0)
            if [[ "$(app_read "$u" "$df" 2>/dev/null | md5sum || true)" != "$before_sum" ]]; then
                n_flow=$((n_flow + 1))
                # What the app's deploy-config had turned off ran once all the
                # same, from the recipe: from the next deploy it does not.
                off=""
                for k in storage_link migrate optimize; do
                    v=$(app_get "$u" "deploy_${k}" 2>/dev/null || true)
                    [[ "$v" == "false" || "$v" == "0" ]] && off="${off} artisan:${k/_/:}"
                done
                [[ -n "$off" ]] && echo "  ${u}: off in its deploy-config, and really skipped from the next deploy:${off}"
            fi
            ;;
        2)
            echo "  ${u}: deploy.php was edited by hand (its own deploy task, or the hooks moved) — left as it is."
            echo "        To have each step once, add the lines of ${CIPI_LIB}/deployer/flow.php to it, or let Cipi write it again"
            echo "        (your edits are lost): cipi app deploy-config ${u} --keep-releases=${kr}"
            ;;
        *)
            echo "  WARNING: ${u}: deploy.php not updated — storage:link, optimize and migrate still run twice (written again by: cipi app deploy-config ${u} --keep-releases=${kr})"
            ;;
    esac
done < <(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)

if (( n_flow > 0 )); then
    echo "  deploy.php: ${n_flow} app(s) run storage:link, migrate and optimize once per deploy"
    log_action "DEPLOY FLOW: ${n_flow} deploy.php updated" 2>/dev/null || true
fi
echo "Migration 5.17.0 complete"
