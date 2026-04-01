#!/bin/bash
#############################################
# Cipi Migration 4.4.12 — Regenerate deploy.php (set vs add writable_dirs)
#
# 4.4.11 used add('writable_dirs') which appended to the Laravel recipe defaults
# (storage, storage/logs). Changed to set() to fully override.
#############################################

set -e

CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"

echo "Migration 4.4.12 — Regenerate deploy.php (set writable_dirs)..."

if [[ -f "${CIPI_LIB}/common.sh" ]]; then
    source "${CIPI_LIB}/common.sh"
fi
if [[ -f "${CIPI_LIB}/app.sh" ]]; then
    source "${CIPI_LIB}/app.sh"
fi

if type _create_deployer_config_for_app &>/dev/null && [[ -f "${CIPI_CONFIG}/apps.json" ]]; then
    while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        [[ "$(app_get "$app" custom)" == "true" ]] && continue
        [[ -f "/home/${app}/.deployer/deploy.php" ]] || continue
        _create_deployer_config_for_app "$app"
        echo "  Regenerated deploy.php for ${app}"
    done < <(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
fi

echo "Migration 4.4.12 complete"
