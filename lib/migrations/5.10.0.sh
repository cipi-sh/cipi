#!/bin/bash
#############################################
# Cipi Migration 5.10.0
#
# FrankenPHP builds pinned per Octane app, JIT per app, and two fixes of a
# fresh server: Deployer 8 (#519) and the panel's vhost (#520).
#
#  1. Installs /usr/local/bin/cipi-frankenphp-link (the Octane recipe runs it
#     as the app user to link the pinned build into each new release) and
#     creates /opt/cipi-frankenphp.
#  2. Pins, for each Octane app, the FrankenPHP binary that is in its live
#     release — the one it runs now (cipi frankenphp adopt). The same bytes:
#     nothing restarts, and the PHP each app answers on does not change.
#  3. Adds the cipi:frankenphp task to each Octane app's deploy.php, in
#     place: what else is in the file stays as it is.
#  4. Rewrites the panel's sudoers (app jit, frankenphp status|upgrade)
#     where a panel is installed.
#  5. Deployer (#519): setup.sh downloaded deployer.org/deployer.phar, which
#     now serves Deployer 6.8.0 (no deploy:publish: every deploy failed). A
#     dep that is not Deployer 8 gets 8.0.5 from its GitHub release, checked
#     against its SHA-256 — except Deployer 7 where an app still runs PHP
#     < 8.3, which Deployer 8 cannot run (cipi_deployer_migrate).
#  6. The web panel's vhost (#520) loses snippets/fastcgi-php.conf, which
#     nginx.org's packages do not ship (gui_vhost_drop_fastcgi_snippet).
#
# Nothing restarts. JIT stays off for every app until `cipi app jit <app> on`.
# The nightly `cipi autoupdate` now includes frankenphp: patch builds on each
# app's own PHP minor (off: cipi autoupdate off frankenphp).
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

echo "Migration 5.10.0 — FrankenPHP builds pinned per Octane app, JIT per app..."

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"
# shellcheck source=/dev/null
source "${CIPI_LIB}/frankenphp.sh"

# ── 1. helper and store ──────────────────────────────────────
LINK_BIN="${CIPI_FRANKENPHP_LINK_BIN:-/usr/local/bin/cipi-frankenphp-link}"
if [[ -f "${CIPI_LIB}/cipi-frankenphp-link.sh" ]] \
   && install -m 755 -o root -g root "${CIPI_LIB}/cipi-frankenphp-link.sh" "$LINK_BIN" 2>/dev/null; then
    echo "  ${LINK_BIN} installed"
else
    echo "  WARNING: could not install ${LINK_BIN} — deploys keep letting Octane download FrankenPHP"
fi
if install -d -m 755 "$FRANKENPHP_ROOT" "$FRANKENPHP_BUILDS" "$FRANKENPHP_APPS" 2>/dev/null; then
    echo "  ${FRANKENPHP_ROOT} ready"
else
    echo "  WARNING: could not create ${FRANKENPHP_ROOT}"
fi

# ── 2. + 3. Octane apps ──────────────────────────────────────
# deploy.php gets the task where the recipe has it: the hook first after
# the vendors (before the migrations), the task before workers:stop.
_mig_dp_add_frankenphp() {   # stdin: deploy.php → stdout
    awk '
        /^after\(.deploy:vendors., .cipi:node_build.\);/ && !h {
            print "// The FrankenPHP build Cipi pinned for this app (cipi frankenphp), linked into"
            print "// the release before it goes live: Octane finds it and downloads nothing. First"
            print "// after the vendors, so a release it refuses has run no migration."
            print "after('"'"'deploy:vendors'"'"', '"'"'cipi:frankenphp'"'"');"
            h = 1
        }
        /^task\(.workers:stop., function/ && !t {
            print "// Without the helper (a server not updated yet) nothing is linked."
            print "task('"'"'cipi:frankenphp'"'"', function () {"
            print "    run('"'"'[ ! -x /usr/local/bin/cipi-frankenphp-link ] || /usr/local/bin/cipi-frankenphp-link {{release_path}}'"'"');"
            print "});"
            print ""
            t = 1
        }
        { print }
        END { if (!h || !t) exit 3 }
    '
}

apps=$(fphp_octane_apps)
if [[ -z "$apps" ]]; then
    echo "  no Octane apps"
else
    while IFS= read -r app; do
        [[ -n "$app" ]] || continue
        id "$app" &>/dev/null || { echo "  ${app}: no such user — skipped"; continue; }

        if [[ -n "$(fphp_app_build "$app")" ]]; then
            echo "  ${app}: already pinned to $(fphp_app_build "$app")"
        elif bid=$(fphp_adopt "$app" 2>/dev/null) && [[ -n "$bid" ]]; then
            echo "  ${app}: pinned to ${bid} (FrankenPHP $(fphp_meta "$bid" frankenphp), PHP $(fphp_meta "$bid" php)) — the binary it runs; nothing restarted"
        else
            echo "  ${app}: no FrankenPHP binary in its live release — pinned at its next deploy (or: cipi frankenphp upgrade ${app})"
        fi

        dp="/home/${app}/.deployer/deploy.php"
        cur=$(app_read "$app" "$dp" || true)
        if [[ -z "$cur" ]]; then
            echo "  ${app}: no deploy.php — skipped"
        elif grep -q "cipi:frankenphp" <<< "$cur"; then
            echo "  ${app}: deploy.php already links FrankenPHP"
        elif new=$(_mig_dp_add_frankenphp <<< "$cur"); then
            if printf '%s\n' "$new" | app_write "$app" "$dp"; then
                echo "  ${app}: deploy.php links the pinned FrankenPHP build"
            else
                echo "  WARNING: ${app}: could not write ${dp}"
            fi
        else
            echo "  WARNING: ${app}: deploy.php does not have the lines of the Octane recipe Cipi writes — add the cipi:frankenphp task by hand (see /opt/cipi/lib/deployer/laravel-octane.php); until then Octane keeps downloading FrankenPHP at each deploy"
        fi
    done <<< "$apps"
fi

# ── 4. Panel sudoers ─────────────────────────────────────────
if [[ -f "${CIPI_LIB}/cipi-api-sudoers.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/cipi-api-sudoers.sh"
    if _cipi_panel_installed; then
        prev=""
        if [[ -f /etc/sudoers.d/cipi-api ]]; then
            prev=$(mktemp 2>/dev/null) && cat /etc/sudoers.d/cipi-api > "$prev" 2>/dev/null || prev=""
        fi
        write_cipi_api_sudoers 2>/dev/null || true
        if ! command -v visudo >/dev/null 2>&1; then
            echo "  wrote /etc/sudoers.d/cipi-api (visudo not available to check it)"
        elif visudo -cqf /etc/sudoers.d/cipi-api >/dev/null 2>&1; then
            echo "  wrote /etc/sudoers.d/cipi-api — the panel may also run: app jit, frankenphp status|upgrade"
        elif [[ -n "$prev" ]]; then
            install -m 0440 "$prev" /etc/sudoers.d/cipi-api 2>/dev/null || true
            echo "  WARNING: the new /etc/sudoers.d/cipi-api did not validate — the previous file was put back. Check: visudo -cf /etc/sudoers.d/cipi-api"
        else
            rm -f /etc/sudoers.d/cipi-api
            echo "  WARNING: /etc/sudoers.d/cipi-api did not validate and was removed — the panel cannot run cipi until: cipi api update"
        fi
        [[ -n "$prev" ]] && rm -f "$prev"
    else
        ensure_cipi_api_sudoers || true
    fi
fi

# ── 5. Deployer ──────────────────────────────────────────────
if [[ -f "${CIPI_LIB}/deployer-install.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/deployer-install.sh"
    cipi_deployer_migrate "${CIPI_DEP_BIN:-/usr/local/bin/dep}" || true
fi

# ── 6. the panel's vhost ─────────────────────────────────────
if [[ -f "${CIPI_LIB}/gui.sh" ]]; then
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/gui.sh"
    gui_vhost_drop_fastcgi_snippet "${CIPI_GUI_VHOST:-/etc/nginx/sites-available/cipi-gui}" || true
fi

if [[ -n "$apps" ]]; then
    echo ""
    echo "  The nightly cipi autoupdate now patches each Octane app's FrankenPHP within"
    echo "  its PHP minor (off: cipi autoupdate off frankenphp). Status: cipi frankenphp"
fi
echo "Migration 5.10.0 complete"
