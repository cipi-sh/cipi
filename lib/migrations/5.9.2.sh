#!/bin/bash
#############################################
# Cipi Migration 5.9.2 — Deployer 8 and the panel's vhost on nginx.org
#
#  1. Deployer (#519). setup.sh downloaded https://deployer.org/deployer.phar,
#     which now serves Deployer 6.8.0: no `deploy:publish`, and every deploy
#     stops at "Task `deploy:publish` not found". A server whose
#     /usr/local/bin/dep is not Deployer 8 gets 8.0.5 from Deployer's GitHub
#     release, checked against its SHA-256 (lib/deployer-install.sh).
#     Deployer 7 is left where an app still runs PHP < 8.3, which Deployer 8
#     cannot run: the migration says which apps, and they move with
#     `cipi app edit <app> --php=8.3` first.
#  2. The web panel's vhost (#520) included snippets/fastcgi-php.conf, which
#     Ubuntu's nginx-common ships and nginx.org's packages — Cipi's since
#     5.9.1 — do not: `cipi gui` failed at its SSL step on a fresh server,
#     and an existing panel would fail at the next nginx reload once the
#     file is gone. The include becomes the line the app vhosts use; nginx
#     is checked and reloaded, and the previous file comes back if nginx
#     refuses the new one.
#
# Each step tolerates failure and says so.
#############################################
set -euo pipefail

export CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
export CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
export CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"

echo "Migration 5.9.2 — Deployer 8, the panel's vhost on nginx.org..."

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"
# shellcheck source=/dev/null
source "${CIPI_LIB}/deployer-install.sh"

# ── 1. Deployer ──────────────────────────────────────────────
DEP="${CIPI_DEP_BIN:-/usr/local/bin/dep}"
cur=$(cipi_deployer_phar_version "$DEP" 2>/dev/null || true)
major="${cur%%.*}"
if [[ "$major" == "${CIPI_DEPLOYER_VERSION%%.*}" ]]; then
    echo "  Deployer ${cur} — nothing to do"
else
    legacy=""
    if [[ "$major" == 7 && -f "${CIPI_CONFIG}/apps.json" ]]; then
        legacy=$(vault_read apps.json 2>/dev/null | jq -r '
            to_entries[] | select((.value.runtime // "") != "node")
            | select((.value.php // "") as $p | ($p | test("^[0-9]+\\.[0-9]+$")) and
                     (($p | split(".") | map(tonumber)) as [$a, $b] | ($a < 8 or ($a == 8 and $b < 3))))
            | "\(.key) (PHP \(.value.php))"' 2>/dev/null | paste -sd, - | sed 's/,/, /g' || true)
    fi
    if [[ -n "$legacy" ]]; then
        echo "  Deployer ${cur} kept: Deployer ${CIPI_DEPLOYER_VERSION%%.*} cannot run on the PHP of ${legacy}."
        echo "  Move them to PHP 8.3 or later (cipi app edit <app> --php=8.3), then:"
        echo "    source /opt/cipi/lib/deployer-install.sh && cipi_deployer_install"
    elif err=$(cipi_deployer_install "$DEP" 2>&1); then
        echo "  Deployer ${cur:-not found} → $(cipi_deployer_phar_version "$DEP")"
        log_action "DEPLOYER: ${cur:-none} → ${CIPI_DEPLOYER_VERSION} (migration 5.9.2)"
    else
        echo "  WARNING: ${err}"
        echo "  Deployer ${cur:-not found} is still at ${DEP}; deploys that need Deployer 8 fail until it is replaced"
    fi
fi

# ── 2. the panel's vhost ─────────────────────────────────────
VH="${CIPI_GUI_VHOST:-/etc/nginx/sites-available/cipi-gui}"
if [[ -f "$VH" ]] && grep -qE '^[[:space:]]*include[[:space:]]+snippets/fastcgi-php\.conf;' "$VH"; then
    bak=$(mktemp)
    cp -p "$VH" "$bak"
    sed -i -E 's|^([[:space:]]*)include[[:space:]]+snippets/fastcgi-php\.conf;|\1try_files $uri =404;|' "$VH"
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || true
        echo "  ${VH}: snippets/fastcgi-php.conf replaced — nginx reloaded"
    else
        cp -p "$bak" "$VH"
        echo "  WARNING: nginx -t refused the new ${VH} — the previous one is back. Check: nginx -t"
    fi
    rm -f "$bak"
else
    echo "  panel vhost: nothing to do"
fi

echo "Migration 5.9.2 complete"
