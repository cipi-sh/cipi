#!/bin/bash
#############################################
# Cipi Migration 5.12.1
#
# Release numbering after the move from Deployer 6 to 8 (5.10.0).
#
# Deployer 7 and 8 number a release from .dep/latest_release and keep the
# list in .dep/releases_log; Deployer 6 numbered from its own .dep/releases
# and wrote neither. On a server that 5.10.0 moved from Deployer 6 to 8 the
# first deploy of every app made release 1, next to the old ones (…, 60, 61):
# cleanup and rollback no longer saw those, and a deploy stopped at
# "Release name "N" already exists" on the first name still taken.
#
#  1. deploy.php of every Laravel, Octane and Node app gets the release_name
#     of lib/deployer/release-name.php: never at or below a release already
#     in releases/ (deployer_release_name_ensure_hook).
#  2. .dep/latest_release is raised to the highest release in releases/, and
#     the Deployer 6 releases go back in .dep/releases_log, before the ones
#     Deployer 8 made (deployer_release_state_repair).
#
# No release is renamed, deleted or switched: `current` stays where it is.
# The next deploy follows the highest release (61 → 62); its cleanup removes
# old releases past keep_releases, Deployer 6 ones included.
#############################################
set -euo pipefail

export CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
export CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
export CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"

echo "Migration 5.12.1 — release numbering after Deployer 6 → 8..."

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"

if [[ ! -f "${CIPI_CONFIG}/apps.json" ]]; then
    echo "  no apps"
    echo "Migration 5.12.1 complete"
    exit 0
fi

n_hook=0
while IFS= read -r u; do
    [[ "$u" =~ ^[a-z][a-z0-9]{2,31}$ ]] || continue
    id "$u" &>/dev/null || continue
    [[ "$(app_get "$u" custom 2>/dev/null || true)" == "true" ]] && continue

    if [[ -f "/home/${u}/.deployer/deploy.php" ]]; then
        before_sum=$(app_read "$u" "/home/${u}/.deployer/deploy.php" 2>/dev/null | md5sum || true)
        if deployer_release_name_ensure_hook "$u"; then
            [[ "$(app_read "$u" "/home/${u}/.deployer/deploy.php" 2>/dev/null | md5sum || true)" != "$before_sum" ]] && n_hook=$((n_hook + 1))
        else
            echo "  WARNING: ${u}: deploy.php not updated — add the lines of ${CIPI_LIB}/deployer/release-name.php by hand"
        fi
    fi

    if out=$(deployer_release_state_repair "$u" 2>&1); then
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            echo "  ${u}: ${line}"
            log_action "RELEASES: ${u} ${line}" 2>/dev/null || true
        done <<< "$out"
    else
        echo "  WARNING: ${u}: release state not repaired${out:+ — ${out}}"
    fi
done < <(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)

(( n_hook > 0 )) && echo "  deploy.php: ${n_hook} app(s) never reuse a release name"
echo "Migration 5.12.1 complete"
