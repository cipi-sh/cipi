#!/bin/bash
#############################################
# Cipi — empty an app's nginx page cache (sudoers-restricted)
#
# The pages nginx keeps for an app (cipi cache <app> on) belong to nginx's
# user: the app's own user cannot delete them. This is the one thing it may
# ask root for — through the rule `cipi cache <app> on` adds to
# /etc/sudoers.d/cipi-<app> — so that a deploy recipe, a script or a plugin
# can empty the cache when the content changes:
#
#   sudo /usr/local/bin/cipi-cache-clear <app>                    every page
#   sudo /usr/local/bin/cipi-cache-clear <app> /blog/post/ /blog/*  some pages
#
# Deploys run by Cipi (cipi deploy, the Git webhook, the panel) empty it by
# themselves; this is for everything else — a Deployer recipe of your own, a
# CI job over SSH, WordPress when a post is published.
#
# It takes the app's name and nothing else, only from that app's user or
# root, and deletes only the files under /var/cache/nginx/cipi/<app>, as
# nginx's user, without following a symlink. With the cache off it does
# nothing and says so. Prints the number of pages deleted.
#
# Usage: cipi-cache-clear <app> [<path|url>…]   (a trailing * : every page under it)
#############################################
set -uo pipefail

# Called through sudo by an app user: nothing from that environment is trusted.
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    unset CIPI_LIB CIPI_CONFIG CIPI_LOG CACHE_ROOT CACHE_CONF_DIR CACHE_NGINX_CONF
fi

APP="${1:-}"
[[ $# -ge 1 && -n "$APP" ]] || { echo "Usage: cipi-cache-clear <app> [<path|url>…]" >&2; exit 2; }
shift
TARGETS=("$@")
[[ "$APP" =~ ^[a-z][a-z0-9]{2,31}$ ]] || { echo "cipi-cache-clear: invalid app name" >&2; exit 2; }
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" && "${SUDO_USER}" != "$APP" ]]; then
    echo "cipi-cache-clear: only '${APP}' (or root) may empty the cache of '${APP}'" >&2
    exit 2
fi
if [[ "$(id -u)" -ne 0 ]]; then
    echo "cipi-cache-clear: run it with sudo — sudo /usr/local/bin/cipi-cache-clear ${APP}" >&2
    exit 2
fi

if [[ -z "${CIPI_LIB:-}" ]]; then readonly CIPI_LIB="/opt/cipi/lib"; fi
if [[ -z "${CIPI_CONFIG:-}" ]]; then readonly CIPI_CONFIG="/etc/cipi"; fi
if [[ -z "${CIPI_LOG:-}" ]]; then readonly CIPI_LOG="/var/log/cipi"; fi

# shellcheck source=/dev/null
source "${CIPI_LIB}/vault.sh" || { echo "cipi-cache-clear: Cipi's libraries are not readable" >&2; exit 1; }
app_get() { vault_read apps.json | jq -r --arg a "$1" --arg k "$2" '.[$a][$k] // empty'; }
# shellcheck source=/dev/null
source "${CIPI_LIB}/cache.sh" || { echo "cipi-cache-clear: lib/cache.sh is missing — cipi self-update" >&2; exit 1; }

if ! cache_enabled "$APP"; then
    echo "The page cache of '${APP}' is off — nothing to empty (cipi cache ${APP} on)"
    exit 0
fi
mkdir -p "$CIPI_LOG" 2>/dev/null || true
if (( ${#TARGETS[@]} > 0 )); then
    (( ${#TARGETS[@]} <= CACHE_PURGE_MAX )) || { echo "cipi-cache-clear: at most ${CACHE_PURGE_MAX} pages at once" >&2; exit 2; }
    for t in "${TARGETS[@]}"; do
        _cache_purge_target "$APP" "$t" >/dev/null || { echo "cipi-cache-clear: not a page of '${APP}': ${t}" >&2; exit 2; }
    done
    n=$(cache_purge "$APP" "${TARGETS[@]}") || { echo "cipi-cache-clear: could not purge the pages of '${APP}'" >&2; exit 1; }
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] PAGE CACHE PURGED: ${APP} (${n}) ${TARGETS[*]:0:5} by ${SUDO_USER:-root}" >> "${CIPI_LOG}/cipi.log" 2>/dev/null || true
    echo "Page cache of '${APP}': ${n} file(s) purged for ${#TARGETS[@]} page(s)"
    exit 0
fi
n=$(cache_clear "$APP") || { echo "cipi-cache-clear: could not empty the cache of '${APP}'" >&2; exit 1; }
echo "[$(date '+%Y-%m-%d %H:%M:%S')] PAGE CACHE CLEARED: ${APP} (${n}) by ${SUDO_USER:-root}" >> "${CIPI_LOG}/cipi.log" 2>/dev/null || true
echo "Page cache of '${APP}' emptied — ${n} page(s)"
exit 0
