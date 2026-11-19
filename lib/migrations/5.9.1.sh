#!/bin/bash
#############################################
# Cipi Migration 5.9.1 — nginx 1.31.9 security release
#
# nginx 1.31.9 (2026-11-18) fixes ten CVEs. How they meet a Cipi server:
#
#   CVE-2026-123007  HTTP/2 flow control, memory corruption      needs HTTP/2
#   CVE-2026-123633  HTTP/2 use-after-free while proxying        needs HTTP/2
#   CVE-2026-118899  endless loop reading a request body over    every HTTPS
#                    TLS 1.3 (a worker stuck at 100% CPU)        vhost
#   CVE-2026-125283  buffer overflow, try_files under an alias   the panel API
#                                                                vhost
#   the rest         resolver, HTTP/3, mail, stream, PROXY       not used by
#                    protocol v2                                 Cipi
#
# Cipi 4 and 5 never turn HTTP/2 on (`listen 443 ssl;`, and nginx has it off
# by default since 1.25.1), so the first two reach a server only where
# someone added it by hand. The other two do not need that.
#
#  1. nginx to nginx.org mainline 1.31.9 or newer. A server already on
#     nginx.org gets the package upgraded. A server on the Ubuntu archive's
#     nginx — every server installed with the setup.sh of 4.6.5 to 5.9.0
#     (10 June to 19 November 2026), which went back to it by mistake — is moved to nginx.org: one apt
#     transaction (simulated first), nginx.conf adapted in place (no
#     headers-more module, max_headers; a copy of the previous one is kept).
#     Then the check the package does not do: that the nginx answering
#     requests is the binary just installed. If the old one is still in
#     memory after a few seconds, nginx is restarted.
#  2. The panel API vhost loses its `alias`: the location's root is already
#     the same directory, and try_files under an alias is what
#     CVE-2026-125283 needs. Tested with nginx -t, put back if refused.
#  3. Says whether HTTP/2 is on anywhere in the loaded configuration.
#  4. Runs `cipi php upgrade` now: the PHP security release of 2026-11-19
#     (8.2.36, 8.3.37, 8.4.28, 8.5.13 — php_security_floor in common.sh) is
#     installed from the repository, FPM restarted, and the patch level of
#     every version printed. A version the repository has no fixed build of
#     is reported as vulnerable, and `cipi pending` keeps saying so.
#
#  5. PHP 8.6: said, not done. A server installed from 5.9.1 on has 8.6 as
#     its PHP; an existing one keeps what it has, and 8.6 is a version the
#     admin adds with `cipi php install 8.6`.
#
# Each step tolerates failure and says so: a migration that aborts pins the
# server on the old release and retries every night.
#############################################
set -euo pipefail

export CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
export CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
export CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; DIM=$'\033[2m'; NC=$'\033[0m'; BOLD=$'\033[1m'

echo "Migration 5.9.1 — nginx 1.31.9 security release (CVE-2026-123007, CVE-2026-123633, CVE-2026-118899, CVE-2026-125283)..."

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"
# shellcheck source=/dev/null
source "${CIPI_LIB}/nginx.sh"

# ── 1. nginx at the security floor, and running it ───────────
if command -v nginx >/dev/null 2>&1; then
    if nginx_security_upgrade; then
        :
    else
        echo "  WARNING: nginx is not on $(nginx_security_floor) or newer yet — run: cipi nginx upgrade   (cipi pending keeps reporting it)"
    fi
else
    echo "  nginx is not installed — nothing to upgrade"
fi

# ── 2. Panel API vhost: no alias under try_files ─────────────
vhost=/etc/nginx/sites-available/cipi-api
if [[ -f "$vhost" ]] && grep -qE '^[[:space:]]*alias[[:space:]]' "$vhost" 2>/dev/null; then
    tmp=$(mktemp 2>/dev/null) || tmp=""
    saved=$(mktemp 2>/dev/null) || saved=""
    if [[ -n "$tmp" && -n "$saved" ]] && cat "$vhost" > "$saved" 2>/dev/null; then
        # Only the alias that says what the server's root already says.
        awk '
            $1 == "root" && r == "" { r = $2; sub(/;$/, "", r) }
            $1 == "alias" && r != "" && $2 == r "/api-docs;" { next }
            { print }' "$saved" > "$tmp" 2>/dev/null || true
        if [[ -s "$tmp" ]] && ! cmp -s "$tmp" "$saved"; then
            cat "$tmp" > "$vhost"
            if nginx -t >/dev/null 2>&1; then
                systemctl reload nginx 2>/dev/null || true
                echo "  Panel API vhost: alias removed from /api-docs (the root is the same directory)"
            else
                cat "$saved" > "$vhost"
                echo "  WARNING: nginx refused the panel API vhost without the alias — put back as it was"
            fi
        else
            echo "  Panel API vhost: its alias is not the one Cipi wrote — left as it is"
        fi
    fi
    rm -f "${tmp:-}" "${saved:-}" 2>/dev/null || true
fi

# ── 3. HTTP/2 ────────────────────────────────────────────────
if command -v nginx >/dev/null 2>&1; then
    h2=$(nginx_http2_listeners 2>/dev/null || true)
    if [[ -n "$h2" ]]; then
        echo "  HTTP/2 is on in configuration Cipi did not write — CVE-2026-123007 and CVE-2026-123633 applied to this server until nginx $(nginx_security_floor):"
        while IFS= read -r f; do
            [[ -n "$f" ]] && echo "    ${f}"
        done <<< "$h2"
    else
        echo "  HTTP/2 is off on this server: CVE-2026-123007 and CVE-2026-123633 could not be reached here"
    fi
fi

# ── 4. PHP packages, now ─────────────────────────────────────
if [[ -f "${CIPI_LIB}/php.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/php.sh"
    echo "  Running cipi php upgrade now..."
    _php_upgrade || echo "  WARNING: a PHP version is below the patched release, or the upgrade failed — run: cipi php upgrade"
fi

# ── 5. PHP 8.6 ───────────────────────────────────────────────
# New servers are installed with it (setup.sh). This one keeps the PHP it
# has: nothing here installs 8.6, moves an app to it or makes it the
# server's PHP.
echo "  PHP 8.6 is not installed by this update: the server keeps its PHP. When you want it: cipi php install 8.6"

echo "Migration 5.9.1 complete"
