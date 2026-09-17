#!/bin/bash
#############################################
# Cipi Migration 5.4.0
#
# Deploy audit ledger. Until now only `cipi deploy` and the webhook wrapper
# wrote deploy banners, and both into a log the app user owns. From here every
# deploy — CLI, Git webhook, cipi/agent (webhook or MCP), panel, or `dep deploy`
# run by hand — is recorded by root in /var/log/cipi/deploys.jsonl through the
# Deployer recipe, which is the one thing all of those share.
#
#  1. Installs /usr/local/bin/cipi-deploy-audit (root-only).
#  2. Adds one sudoers rule per app so its recipe can call it
#     (validated with visudo; a rejected file is put back).
#  3. Appends the audit hooks to each app's deploy.php, keeping every other
#     line of the file as it is.
#  4. Points each app's ~/.deploy-trigger cron at `mv` instead of `rm`, so the
#     wrapper can read who asked for the deploy (source/actor/ip/request_id)
#     when cipi/agent writes it into the trigger file.
#  5. Records when auditing started, so `cipi compliance deploys` does not
#     flag releases published before this update.
#  6. Node 20 reached end of life in April 2026: a server whose Node is still 20
#     (the NodeSource package setup.sh used to install) switches to Node 22 with
#     `cipi node default 22` — the official build under /opt/cipi/node/22, linked
#     into /usr/local/bin. The NodeSource package is not touched, so
#     `cipi node default system` goes back. A server already on another major
#     is left alone. If the download fails, the server stays on 20 and the
#     migration carries on.
#
# Nothing is deployed, restarted or reloaded.
#############################################
# Every step tolerates failure and carries on: an aborted migration pins the
# server on the old version and retries every night.
set -euo pipefail

export CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
export CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
export CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"

# common.sh's info/warn/success print these; the cipi binary defines them, a
# migration runs without it (and under set -u).
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; DIM=$'\033[2m'; NC=$'\033[0m'; BOLD=$'\033[1m'

echo "Migration 5.4.0 — deploy audit ledger..."

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"

# ── 1. helper ────────────────────────────────────────────────
if [[ -f "${CIPI_LIB}/cipi-deploy-audit.sh" ]]; then
    if cp "${CIPI_LIB}/cipi-deploy-audit.sh" /usr/local/bin/cipi-deploy-audit 2>/dev/null; then
        chmod 700 /usr/local/bin/cipi-deploy-audit 2>/dev/null || true
        chown root:root /usr/local/bin/cipi-deploy-audit 2>/dev/null || true
        echo "  installed /usr/local/bin/cipi-deploy-audit"
    else
        echo "  WARNING: could not write /usr/local/bin/cipi-deploy-audit"
    fi
fi
mkdir -p "${CIPI_LOG}" 2>/dev/null || true
if [[ ! -f "${CIPI_LOG}/deploys.jsonl" ]]; then
    (umask 077; : > "${CIPI_LOG}/deploys.jsonl") 2>/dev/null || true
fi
chmod 600 "${CIPI_LOG}/deploys.jsonl" 2>/dev/null || true

# ── 5. start marker (kept if already there) ──────────────────
install -d -m 700 -o root -g root /var/lib/cipi 2>/dev/null || true
if [[ ! -s /var/lib/cipi/deploy-audit-since ]]; then
    date -u '+%Y-%m-%dT%H:%M:%SZ' > /var/lib/cipi/deploy-audit-since 2>/dev/null || true
    chmod 600 /var/lib/cipi/deploy-audit-since 2>/dev/null || true
fi

apps=""
if [[ -f "${CIPI_CONFIG}/apps.json" ]]; then
    apps=$(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
fi

while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    id "$app" &>/dev/null || continue

    # ── 2. sudoers
    sudoers="/etc/sudoers.d/cipi-${app}"
    if [[ -f "$sudoers" ]] && ! grep -q "cipi-deploy-audit ${app} \*\$" "$sudoers"; then
        if cp "$sudoers" "${sudoers}.cipi-bak" 2>/dev/null; then
            echo "${app} ALL=(root) NOPASSWD: /usr/local/bin/cipi-deploy-audit ${app} *" >> "$sudoers"
            chmod 440 "$sudoers"
            if visudo -cf "$sudoers" &>/dev/null; then
                rm -f "${sudoers}.cipi-bak"
                echo "  ${app}: sudoers rule for the deploy audit added"
            else
                mv "${sudoers}.cipi-bak" "$sudoers"
                chmod 440 "$sudoers"
                echo "  WARNING: ${app}: sudoers rule rejected — left unchanged"
            fi
        fi
    fi

    # ── 3. deploy.php hooks
    df="/home/${app}/.deployer/deploy.php"
    if [[ -f "$df" ]]; then
        if grep -q 'cipi:deploy-audit' "$df" 2>/dev/null; then
            :
        elif deployer_audit_ensure_hook "$app"; then
            echo "  ${app}: deploy audit hooks added to deploy.php"
        else
            echo "  WARNING: ${app}: could not add the deploy audit hooks to ${df}"
        fi
    fi

    # ── 4. trigger cron: keep the trigger file for the wrapper to read
    cur=$(crontab -u "$app" -l 2>/dev/null || true)
    if [[ -n "$cur" ]] && grep -q '\.deploy-trigger && rm -f ' <<< "$cur"; then
        new=$(printf '%s\n' "$cur" | sed -E \
            "s#test -f (/home/${app}/\\.deploy-trigger) && rm -f /home/${app}/\\.deploy-trigger && #test -f \\1 \\&\\& mv -f \\1 \\1.run \\&\\& #")
        if [[ "$new" != "$cur" ]] && printf '%s\n' "$new" | crontab -u "$app" - 2>/dev/null; then
            echo "  ${app}: webhook trigger cron hands the trigger file to the wrapper"
        else
            echo "  WARNING: ${app}: could not rewrite the crontab — left unchanged"
        fi
    fi
done <<< "$apps"

echo "  deploy audit ledger: ${CIPI_LOG}/deploys.jsonl"

# ── 6. server Node 20 → 22 ───────────────────────────────────
if [[ -f "${CIPI_LIB}/node.sh" ]]; then
    # shellcheck source=/dev/null
    [[ -f "${CIPI_LIB}/notifications.sh" ]] && source "${CIPI_LIB}/notifications.sh" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/node.sh"
    node_cur_default=$(node_default_major)
    node_sys_major=$(/usr/bin/node --version 2>/dev/null | sed -nE 's/^v([0-9]+)\..*/\1/p' || true)
    if [[ "$node_cur_default" == "20" || ( -z "$node_cur_default" && "$node_sys_major" == "20" ) ]]; then
        # Subshell: _node_default_cmd exits on a failed download, and that must
        # not take the migration (and the whole update) down with it.
        if ( _node_default_cmd 22 ) >/dev/null 2>&1; then
            echo "  server Node 20 → $(node_full_version 22 || echo 22) (cipi node default system reverts)"
        else
            echo "  WARNING: could not switch the server to Node 22 — still on Node 20. Retry: cipi node default 22"
        fi
    elif [[ -n "$node_cur_default" ]]; then
        echo "  server Node: ${node_cur_default} (managed) — unchanged"
    elif [[ -n "$node_sys_major" ]]; then
        echo "  server Node: ${node_sys_major} (system) — unchanged"
    fi
fi
