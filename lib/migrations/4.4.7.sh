#!/bin/bash
#############################################
# Cipi Migration 4.4.7 — Fix 4.4.6 log ACL side effects
#
# - common.sh could be sourced with CIPI_LOG unset → mkdir ''.
# - Per-file ACLs on shared/storage/logs broke Deployer chmod (EPERM).
# This migration strips file/default ACLs introduced by 4.4.6 and reapplies
# directory-only traversal ACLs.
#############################################

set -e

CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"

echo "Migration 4.4.7 — fix log ACLs + CIPI_LOG default..."

if [[ -d /home ]]; then
    for d in /home/*/logs; do
        [[ -d "$d" ]] || continue
        setfacl -k "$d" 2>/dev/null || true
        find "$d" -type f -exec setfacl -b {} \; 2>/dev/null || true
    done
    for d in /home/*/shared/storage/logs; do
        [[ -d "$d" ]] || continue
        setfacl -k "$d" 2>/dev/null || true
        find "$d" -type f -exec setfacl -b {} \; 2>/dev/null || true
    done
fi

if [[ -f "${CIPI_LIB}/common.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/common.sh"
fi

if type ensure_app_logs_permissions &>/dev/null; then
    if [[ -f "${CIPI_CONFIG}/apps.json" ]] && command -v jq &>/dev/null; then
        while IFS= read -r app; do
            [[ -n "$app" ]] && ensure_app_logs_permissions "$app"
        done < <(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
    fi
    for home in /home/*/; do
        u=$(basename "$home")
        [[ "$u" == "cipi" ]] && continue
        [[ -d "${home}/logs" ]] || continue
        id "$u" &>/dev/null || continue
        ensure_app_logs_permissions "$u"
    done
fi

echo "Migration 4.4.7 complete"
