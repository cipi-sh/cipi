#!/bin/bash
#############################################
# Cipi Migration 5.2.0
#
# Three jobs, all of them repairs to the upgrade path itself:
#
# 1. Keep SSH_CLIENT across sudo. `cipi crowdsec enable` allowlists the SSH
#    session it is typed from so the operator cannot be banned by the engine
#    they just switched on. It reads SSH_CLIENT / SSH_CONNECTION, and sudo's
#    env_reset drops both. Installs made before this release wrote only
#    SSH_USER_AUTH into env_keep, and since setup.sh sets PermitRootLogin=no
#    the normal path *is* `sudo cipi`.
#
# 2. Install the helper binaries this release adds. self-update never re-execs,
#    so the copy loop running right now is the *pre-5.2.0* one: it copies
#    lib/*.sh into /opt/cipi/lib and knows nothing about cipi-scan-manifest or
#    the rescue listener. Without this block `cipi crowdsec enable` fails with
#    "Rescue helpers missing" on every upgraded server, and no deploy writes an
#    integrity manifest, so the nightly scan reports drift for every release.
#
# 3. Let each app refresh its own integrity manifest through one narrow sudo
#    entry. The manifest now lives in /var/lib/cipi/manifests (root:root 0600)
#    instead of /home/<app>/shared, where the app user — and therefore any
#    webshell in the app — could rewrite the baseline it is checked against.
#
# CrowdSec and the scan themselves stay off: 5.2.0 is opt-in.
#############################################

# Every step below tolerates failure and carries on. A migration that aborts
# makes self-update refuse the whole release and pins the server on the old
# version, retrying and failing every night.
set -euo pipefail

export CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
export CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
export CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"

GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; DIM=$'\033[2m'; NC=$'\033[0m'

echo "Migration 5.2.0 — sudo env, 5.2.0 helpers, per-app manifest permission..."

# ─────────────────────────────────────────────────────────────
# 1. env_keep += SSH_CLIENT SSH_CONNECTION
# ─────────────────────────────────────────────────────────────
SUDOERS="/etc/sudoers.d/cipi-sudo"

patch_env_keep() {
    if [[ ! -f "$SUDOERS" ]]; then
        echo -e "  ${DIM}${SUDOERS} not present — nothing to patch${NC}"
        return 0
    fi
    if grep -q 'env_keep.*SSH_CLIENT' "$SUDOERS"; then
        echo -e "  ${DIM}env_keep already carries SSH_CLIENT${NC}"
        return 0
    fi

    local tmp; tmp=$(mktemp)
    cp "$SUDOERS" "$tmp"

    if grep -q '^Defaults:cipi env_keep' "$tmp"; then
        sed -i 's|^Defaults:cipi env_keep += "SSH_USER_AUTH"$|Defaults:cipi env_keep += "SSH_USER_AUTH SSH_CLIENT SSH_CONNECTION"|' "$tmp"
    else
        sed -i '1i Defaults:cipi env_keep += "SSH_USER_AUTH SSH_CLIENT SSH_CONNECTION"' "$tmp"
    fi

    if ! grep -q 'SSH_CLIENT' "$tmp"; then
        echo -e "  ${YELLOW}⚠${NC} could not rewrite env_keep in ${SUDOERS} — leaving it alone"
        echo -e "  ${DIM}Add by hand: Defaults:cipi env_keep += \"SSH_CLIENT SSH_CONNECTION\"${NC}"
        rm -f "$tmp"; return 0
    fi

    # A malformed sudoers file locks the cipi user out of root entirely, so the
    # candidate is validated before it goes anywhere near /etc/sudoers.d.
    if command -v visudo >/dev/null 2>&1; then
        if ! visudo -cqf "$tmp" >/dev/null 2>&1; then
            echo -e "  ${YELLOW}⚠${NC} the patched sudoers did not validate — keeping the current one"
            rm -f "$tmp"; return 0
        fi
    else
        # sudo-rs and trimmed images may not ship visudo. Refusing here would
        # make the migration a silent no-op, so go ahead: the only edit is one
        # Defaults line, and the backup below is the way back.
        echo -e "  ${DIM}visudo not available — installing without validation${NC}"
    fi

    # The backup goes outside /etc/sudoers.d: sudo parses everything in that
    # directory and only skips names containing a dot, too subtle to rely on.
    cp -p "$SUDOERS" "${CIPI_CONFIG}/cipi-sudo.bak.5.2.0" 2>/dev/null || true

    if ! install -m 440 -o root -g root "$tmp" "$SUDOERS" 2>/dev/null; then
        echo -e "  ${YELLOW}⚠${NC} could not replace ${SUDOERS} — the original is untouched"
        echo -e "  ${DIM}Add by hand: Defaults:cipi env_keep += \"SSH_CLIENT SSH_CONNECTION\"${NC}"
        echo -e "  ${DIM}Until then: cipi crowdsec allow <your-ip> before enabling CrowdSec.${NC}"
        rm -f "$tmp"; return 0
    fi
    rm -f "$tmp"
    echo -e "  ${GREEN}✓${NC} ${SUDOERS}: SSH_CLIENT / SSH_CONNECTION now survive sudo"
    echo -e "  ${DIM}Takes effect on your next sudo (current shell keeps the old env).${NC}"
}

# ─────────────────────────────────────────────────────────────
# 2. Install the binaries the running (pre-5.2.0) self-update does not know
# ─────────────────────────────────────────────────────────────
install_helpers() {
    local src=""
    # The fresh clone is the only place that carries the .py: self-update copies
    # lib/*.sh into /opt/cipi/lib, so a Python file never lands there.
    if [[ -n "${CIPI_UPDATE_TMP:-}" && -d "${CIPI_UPDATE_TMP}/lib" ]]; then
        src="${CIPI_UPDATE_TMP}/lib"
    elif [[ -d "$CIPI_LIB" ]]; then
        src="$CIPI_LIB"
    else
        echo -e "  ${YELLOW}⚠${NC} no source tree for the 5.2.0 helpers — run: cipi self-update"
        return 0
    fi

    local installed=0 name dest mode
    while read -r name dest mode; do
        [[ -f "${src}/${name}" ]] || continue
        if install -m "$mode" -o root -g root "${src}/${name}" "$dest" 2>/dev/null; then
            installed=$((installed + 1))
        else
            echo -e "  ${YELLOW}⚠${NC} could not install ${dest}"
        fi
    done <<'HELPERS'
cipi-scan-manifest.sh /usr/local/bin/cipi-scan-manifest 755
cipi-crowdsec-rescue.py /usr/local/bin/cipi-crowdsec-rescue 700
cipi-crowdsec-rescue-hole.sh /usr/local/bin/cipi-crowdsec-rescue-hole 700
HELPERS

    if [[ "$installed" -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} installed ${installed} 5.2.0 helper(s) in /usr/local/bin"
    fi
    if [[ ! -x /usr/local/bin/cipi-scan-manifest ]]; then
        echo -e "  ${YELLOW}⚠${NC} cipi-scan-manifest missing — deploys will not refresh integrity manifests"
    fi
    if [[ ! -x /usr/local/bin/cipi-crowdsec-rescue ]]; then
        # Phrased without the literal command: this migration must never look
        # like it turns an opt-in feature on, and tests/verify-5.2.0.sh checks.
        echo -e "  ${YELLOW}⚠${NC} rescue listener missing — enabling CrowdSec would refuse to start it"
    fi

    # The listener holds the old code in memory until it is restarted.
    if systemctl is-active --quiet cipi-crowdsec-rescue 2>/dev/null; then
        systemctl restart cipi-crowdsec-rescue 2>/dev/null || true
    fi
}

# ─────────────────────────────────────────────────────────────
# 3. Manifest store + one narrow sudo entry per app
# ─────────────────────────────────────────────────────────────
manifest_store() {
    # 0700 root:root: the point of moving manifests out of /home/<app> is that
    # the app user cannot read or rewrite its own baseline.
    install -d -m 700 -o root -g root /var/lib/cipi/manifests 2>/dev/null \
        || echo -e "  ${YELLOW}⚠${NC} could not create /var/lib/cipi/manifests"

    # Manifests written by 5.2.0 pre-releases sat inside the app tree. They are
    # untrustworthy by construction (the app user could edit them), so drop them
    # rather than migrate them; the next deploy writes a real one.
    local old
    for old in /home/*/shared/.cipi-manifest /home/*/.cipi-manifest; do
        [[ -f "$old" ]] && rm -f "$old" 2>/dev/null || true
    done
}

patch_app_sudoers() {
    local f app added=0 tmp
    for f in /etc/sudoers.d/cipi-*; do
        [[ -f "$f" ]] || continue
        case "$(basename "$f")" in
            cipi-sudo|cipi-api|*-yml) continue ;;
        esac
        # The app name is whatever the existing worker rule is pinned to; that
        # keeps this from guessing at file names.
        app=$(awk '/cipi-worker restart /{print $1; exit}' "$f" 2>/dev/null)
        [[ "$app" =~ ^[a-z][a-z0-9]{2,31}$ ]] || continue
        grep -q "cipi-scan-manifest ${app}\$" "$f" 2>/dev/null && continue

        tmp=$(mktemp)
        cp "$f" "$tmp"
        printf '%s ALL=(root) NOPASSWD: /usr/local/bin/cipi-scan-manifest %s\n' "$app" "$app" >> "$tmp"
        if command -v visudo >/dev/null 2>&1 && ! visudo -cqf "$tmp" >/dev/null 2>&1; then
            echo -e "  ${YELLOW}⚠${NC} sudoers for ${app} did not validate — left unchanged"
            rm -f "$tmp"; continue
        fi
        if install -m 440 -o root -g root "$tmp" "$f" 2>/dev/null; then
            added=$((added + 1))
        else
            echo -e "  ${YELLOW}⚠${NC} could not update $(basename "$f")"
        fi
        rm -f "$tmp"
    done
    if [[ "$added" -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} ${added} app(s) may now refresh their own integrity manifest via sudo"
    fi
}

patch_env_keep   || echo -e "  ${YELLOW}⚠${NC} env_keep step skipped"
install_helpers  || echo -e "  ${YELLOW}⚠${NC} helper install step skipped"
manifest_store   || echo -e "  ${YELLOW}⚠${NC} manifest store step skipped"
patch_app_sudoers || echo -e "  ${YELLOW}⚠${NC} per-app sudoers step skipped"

exit 0
