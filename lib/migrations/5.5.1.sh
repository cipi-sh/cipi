#!/bin/bash
#############################################
# Cipi Migration 5.5.1
#
# Certificates: Cipi writes the HTTPS vhost, certbot only issues and renews.
#
# `cipi ssl install` and every vhost regeneration (alias, www, basic auth,
# redirects, Octane, Reverb, suspend) put HTTPS back with `certbot install
# --nginx`. certbot's nginx installer always asks which server block to use
# for a wildcard name and cannot be answered with --non-interactive, so a
# wildcard certificate was issued and then never installed ("Could not install
# certificate"), and every later regeneration dropped HTTPS without a word.
#
#  1. A certbot deploy hook reloads nginx after every renewal. Nothing reloaded
#     it after certbot.timer renewed a DNS-01 certificate: nginx kept serving
#     the old one until it expired.
#  2. The weekly renewal cron no longer passes --nginx, which forced HTTP-01 on
#     every certificate — a DNS-01 wildcard cannot renew that way.
#  3. Writes the TLS settings shared by app vhosts (/etc/nginx/snippets/cipi-ssl.conf).
#  4. Apps whose certificate was issued over DNS-01 but not recorded as such
#     (the install stopped at the certbot install step) are marked, so that the
#     next `cipi ssl install` reissues over DNS-01 and keeps the wildcard.
#  5. Rewrites the vhost of the apps that need it, now with the HTTPS block
#     written by Cipi: a certificate holding a wildcard name, an app serving a
#     wildcard name, a Cloudflare Origin CA certificate, or a certificate the
#     vhost does not serve at all. One app at a time: the previous file is kept
#     in /var/lib/cipi/vhost-backup-5.5.1 and put back if nginx refuses the new
#     one. Other apps keep their certbot-written vhost until it is next
#     regenerated.
#
# No certificate is requested or renewed. Nothing is deployed.
#############################################
# Every step tolerates failure and carries on: an aborted migration pins the
# server on the old version and retries every night.
set -euo pipefail

export CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
export CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
export CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; DIM=$'\033[2m'; NC=$'\033[0m'; BOLD=$'\033[1m'

echo "Migration 5.5.1 — HTTPS vhosts written by Cipi, wildcard certificates..."

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"

# ── 1. reload nginx after every renewal ──────────────────────
if command -v certbot >/dev/null 2>&1 || [[ -d /etc/letsencrypt ]]; then
    if certbot_ensure_reload_hook; then
        echo "  certbot: nginx reloads after every renewed certificate (${CIPI_CERTBOT_RELOAD_HOOK})"
    else
        echo "  WARNING: could not write ${CIPI_CERTBOT_RELOAD_HOOK}"
    fi
fi

# ── 2. weekly renewal without --nginx ────────────────────────
cron_now=$(crontab -l 2>/dev/null || true)
if grep -q 'certbot renew --nginx' <<< "$cron_now"; then
    if sed 's|certbot renew --nginx |certbot renew |' <<< "$cron_now" | crontab - 2>/dev/null; then
        echo "  cron: weekly renewal no longer forces HTTP-01 (--nginx removed)"
    else
        echo "  WARNING: could not rewrite the root crontab — remove --nginx from the certbot renew line by hand"
    fi
fi

# ── 3. TLS settings ──────────────────────────────────────────
if [[ -d /etc/nginx ]]; then
    nginx_ensure_ssl_snippet || echo "  WARNING: could not write ${CIPI_NGINX_SSL_SNIPPET}"
fi

apps=""
if [[ -f "${CIPI_CONFIG}/apps.json" ]]; then
    apps=$(vault_read apps.json 2>/dev/null | jq -r 'keys[]' 2>/dev/null || true)
fi
[[ -n "$apps" ]] || { echo "Migration 5.5.1 complete (no apps)"; exit 0; }
command -v nginx >/dev/null 2>&1 || { echo "Migration 5.5.1 complete (no nginx)"; exit 0; }

# shellcheck source=/dev/null
source "${CIPI_LIB}/app.sh"

renewal_dir="/etc/letsencrypt/renewal"
default_creds="/etc/cipi/cloudflare.ini"
backup_dir="/var/lib/cipi/vhost-backup-5.5.1"
rewrote=0

while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    vhost="/etc/nginx/sites-available/${app}"
    [[ -f "$vhost" ]] || continue
    dom=$(app_get "$app" domain 2>/dev/null || true)
    php_ver=$(app_get "$app" php 2>/dev/null || true)
    [[ -n "$dom" ]] || continue
    cert_name=$(domain_cert_name "$dom")

    # ── 4. DNS-01 certificates the app does not know about ──
    conf="${renewal_dir}/${cert_name}.conf"
    if [[ -f "$conf" && -z "$(app_get "$app" ssl_dns_provider 2>/dev/null || true)" ]]; then
        creds=$(sed -n 's/^dns_cloudflare_credentials[[:space:]]*=[[:space:]]*//p' "$conf" 2>/dev/null | head -1 || true)
        creds="${creds%"${creds##*[![:space:]]}"}"
        if [[ -n "$creds" ]]; then
            account="default"
            if [[ "$creds" != "$default_creds" ]]; then account="${creds##*/}"; account="${account%.ini}"; fi
            app_set "$app" ssl_dns_provider "cloudflare" 2>/dev/null || true
            app_set "$app" ssl_dns_account "$account" 2>/dev/null || true
            echo "  ${app}: certificate renews over DNS-01 (Cloudflare account ${account}) — recorded"
        fi
    fi

    files=$(app_tls_files "$app" 2>/dev/null || true)
    [[ -n "$files" ]] || continue
    cert_file="${files%%$'\t'*}"
    names=$(cert_file_names "$cert_file")

    # A certificate issued with --wildcard keeps "*.<apex>" on every reissue.
    apex="$cert_name"; [[ "$apex" == www.* ]] && apex="${apex#www.}"
    if grep -qxF "*.${apex}" <<< "$names" && [[ -n "$(app_get "$app" ssl_dns_provider 2>/dev/null || true)" ]]; then
        app_set "$app" ssl_wildcard "true" 2>/dev/null || true
    fi

    # ── 5. which vhosts to rewrite ──
    reason=""
    if grep -q '^\*\.' <<< "$names"; then
        reason="the certificate holds a wildcard name"
    elif domain_is_wildcard "$dom" || vault_read apps.json 2>/dev/null \
            | jq -e --arg a "$app" '(.[$a].aliases // []) | any(startswith("*."))' >/dev/null 2>&1; then
        reason="the app serves a wildcard name"
    elif [[ "$(app_get "$app" ssl_origin_ca 2>/dev/null || true)" == "true" ]]; then
        reason="Cloudflare Origin CA certificate"
    elif ! grep -qE '^[[:space:]]*ssl_certificate[[:space:]]' "$vhost" 2>/dev/null; then
        reason="it has a certificate but no HTTPS"
    fi
    [[ -n "$reason" ]] || continue

    mkdir -p "$backup_dir" 2>/dev/null || true
    if ! cp -p "$vhost" "${backup_dir}/${app}" 2>/dev/null; then
        echo "  WARNING: ${app}: could not back up the vhost — left unchanged"
        continue
    fi
    if _create_nginx_vhost "$app" "$dom" "$php_ver" >/dev/null 2>&1 \
       && grep -qE '^[[:space:]]*ssl_certificate[[:space:]]' "$vhost" 2>/dev/null \
       && nginx -t >/dev/null 2>&1; then
        rewrote=$((rewrote + 1))
        echo "  ${app}: vhost rewritten with HTTPS by Cipi (${reason})"
    else
        cp -p "${backup_dir}/${app}" "$vhost" 2>/dev/null || true
        echo "  WARNING: ${app}: the HTTPS vhost could not be written or nginx refused it — previous file kept (${reason})"
    fi
done <<< "$apps"

if [[ "$rewrote" -gt 0 ]]; then
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || true
        echo "  nginx: reloaded — ${rewrote} vhost(s) rewritten, previous files in ${backup_dir}"
    else
        echo "  WARNING: nginx -t fails — check: nginx -t (previous vhosts in ${backup_dir})"
    fi
fi

echo "Migration 5.5.1 complete"
