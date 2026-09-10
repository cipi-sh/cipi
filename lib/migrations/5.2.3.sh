#!/bin/bash
#############################################
# Cipi Migration 5.2.3
#
#  1. Install the cipi-app-post-deploy wrapper and refresh the webhook
#     deploy script that calls it.
#  2. Deny public access to cipi.yml / cipi.yaml on every app vhost.
#     Custom apps serve htdocs/ as the document root, so a committed file
#     was otherwise a GET away. Injected in place — regenerating would
#     drop certbot's :443 block.
#############################################
set -euo pipefail

export CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
export CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
export CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"

echo "Migration 5.2.3 — post-deploy wrapper + hide cipi.yml from the web..."

if [[ -f "${CIPI_LIB}/cipi-app-post-deploy.sh" ]]; then
    cp "${CIPI_LIB}/cipi-app-post-deploy.sh" /usr/local/bin/cipi-app-post-deploy
    chmod 755 /usr/local/bin/cipi-app-post-deploy
    chown root:root /usr/local/bin/cipi-app-post-deploy
    echo "  installed /usr/local/bin/cipi-app-post-deploy"
fi

if [[ -f "${CIPI_LIB}/cipi-app-deploy.sh" ]]; then
    cp "${CIPI_LIB}/cipi-app-deploy.sh" /usr/local/bin/cipi-app-deploy
    chmod 755 /usr/local/bin/cipi-app-deploy
    chown root:root /usr/local/bin/cipi-app-deploy
    echo "  refreshed /usr/local/bin/cipi-app-deploy"
fi

# ── Deny cipi.yml on existing vhosts ─────────────────────────
# `set -e` is deliberate, but every individual vhost is written to tolerate
# failure and carry on. A migration that aborts pins the server on the old
# version and retries every night.
# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"

apps=""
if [[ -f "${CIPI_CONFIG}/apps.json" ]]; then
    apps=$(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
fi

_inject_cipi_yml_deny() {
    local vhost="$1" tmp line
    grep -qF 'cipi\.ya?ml$' "$vhost" 2>/dev/null && return 1
    grep -qF 'location ~ /\.(?!well-known)' "$vhost" 2>/dev/null || return 1
    tmp=$(mktemp) || return 1
    # Insert immediately before the hidden-files deny in every server block
    # (HTTP and the certbot-cloned :443 copy).
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == *'location ~ /\.(?!well-known)'* ]]; then
            printf '    location ~* /cipi\.ya?ml$ { deny all; }\n'
        fi
        printf '%s\n' "$line"
    done < "$vhost" > "$tmp" || { rm -f "$tmp"; return 1; }
    if ! grep -qF 'cipi\.ya?ml$' "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$vhost"
    return 0
}

if [[ -n "$apps" ]] && command -v nginx &>/dev/null && [[ -d /etc/nginx/sites-available ]]; then
    backup_dir="/var/lib/cipi/vhost-backup-5.2.3"
    rewrote=""
    while IFS= read -r app; do
        [[ -n "$app" ]] || continue
        vhost="/etc/nginx/sites-available/${app}"
        [[ -f "$vhost" ]] || continue
        mkdir -p "$backup_dir" 2>/dev/null || true
        cp "$vhost" "${backup_dir}/${app}" 2>/dev/null || continue
        if _inject_cipi_yml_deny "$vhost"; then
            rewrote="${rewrote} ${app}"
            echo "  ${app}: nginx now denies /cipi.yml"
        fi
    done <<< "$apps"

    if [[ -n "$rewrote" ]]; then
        if nginx -t &>/dev/null; then
            systemctl reload nginx 2>/dev/null || true
            echo "  nginx: reloaded (previous vhosts kept in ${backup_dir})"
        else
            for app in $rewrote; do
                cp "${backup_dir}/${app}" "/etc/nginx/sites-available/${app}" 2>/dev/null || true
            done
            echo "  WARNING: nginx test failed after denying cipi.yml — every vhost was restored from ${backup_dir}"
        fi
    fi
fi

echo "Migration 5.2.3 complete."
