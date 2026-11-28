#!/bin/bash
#############################################
# Cipi Migration 5.18.0
#
#  Deploys. Deployer stops a command after 300 seconds, whatever it is, and the
#  frontend build of a deploy — `npm ci && npm run build` on a small server, or
#  one that is busy with something else — is the step that takes longer: the
#  deploy ended at
#
#      The command ".../.deployer/node-build.sh ..." exceeded the timeout of
#      300 seconds.
#
#  some days and not others. The recipes now give the build a limit of its own
#  (30 minutes): the node_build of a Laravel or Octane app, the install and the
#  build of a Node app. deploy.php of every app gets the lines of the recipe it
#  would be given today (deployer_build_timeout_ensure_hook). Every other step
#  of a deploy keeps the 300 seconds.
#
#  A deploy.php whose build tasks are not the ones Cipi wrote is left as it is
#  and named. Custom (classic) apps have no build step.
#
# Nothing restarts, nothing is deployed: the next deploy of each app is the
# first one with the new limit. The mesh network of Zero Trust (cipi zt
# tailscale|netbird) and the Coming soon page are off until someone uses them.
#############################################
set -euo pipefail

export CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
export CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
export CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"

echo "Migration 5.18.0 — a time limit of its own for the build step of a deploy..."

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"

if [[ ! -f "${CIPI_CONFIG}/apps.json" ]]; then
    echo "  no apps"
    echo "Migration 5.18.0 complete"
    exit 0
fi
if ! declare -f deployer_build_timeout_ensure_hook >/dev/null 2>&1; then
    echo "  WARNING: common.sh has no deployer_build_timeout_ensure_hook — nothing changed"
    echo "Migration 5.18.0 complete"
    exit 0
fi

n_build=0
while IFS= read -r u; do
    [[ "$u" =~ ^[a-z][a-z0-9]{2,31}$ ]] || continue
    id "$u" &>/dev/null || continue
    runtime=$(app_get "$u" runtime 2>/dev/null || true)
    # A Node app is a custom app with a runtime; the classic ones build nothing.
    [[ "$runtime" != "node" && "$(app_get "$u" custom 2>/dev/null || true)" == "true" ]] && continue
    df="/home/${u}/.deployer/deploy.php"
    [[ -f "$df" ]] || continue

    before_sum=$(app_read "$u" "$df" 2>/dev/null | md5sum || true)
    rc=0
    deployer_build_timeout_ensure_hook "$u" || rc=$?
    # How to have Cipi write the recipe again, for the two messages below.
    again=$(deployer_recipe_again_cmd "$u")
    case "$rc" in
        0)
            [[ "$(app_read "$u" "$df" 2>/dev/null | md5sum || true)" != "$before_sum" ]] && n_build=$((n_build + 1))
            ;;
        2)
            echo "  ${u}: deploy.php was edited by hand (its build task is not the one Cipi wrote) — left as it is:"
            echo "        the build still stops after Deployer's 300 seconds. To give it 30 minutes, let Cipi write the"
            echo "        recipe again (your edits are lost): ${again}"
            ;;
        *)
            echo "  WARNING: ${u}: deploy.php not updated — the build still stops after 300 seconds (written again by: ${again})"
            ;;
    esac
done < <(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)

if (( n_build > 0 )); then
    echo "  deploy.php: ${n_build} app(s) give the build step 30 minutes instead of 300 seconds"
    log_action "DEPLOY BUILD TIMEOUT: ${n_build} deploy.php updated" 2>/dev/null || true
else
    echo "  deploy.php: nothing to change"
fi
# The page cache: a plugin or a script may purge some pages of its app
# (cipi-cache-clear <app> <path>…), not only all of them.
if [[ -f "${CIPI_LIB}/cache.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/cache.sh" 2>/dev/null || true
    if declare -f _cache_sudoers_ensure >/dev/null 2>&1; then
        n_sud=0
        while IFS= read -r u; do
            [[ "$u" =~ ^[a-z][a-z0-9]{2,31}$ && -f "/etc/sudoers.d/cipi-${u}" ]] || continue
            _cache_sudoers_ensure "$u" && n_sud=$((n_sud + 1)) || echo "  WARNING: /etc/sudoers.d/cipi-${u} left as it is (visudo refused the new rule)"
        done < <(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null)
        echo "  page cache: ${n_sud} app(s) may purge some of their pages (sudo cipi-cache-clear <app> <path>…)"
    fi
fi

echo "Migration 5.18.0 complete"
