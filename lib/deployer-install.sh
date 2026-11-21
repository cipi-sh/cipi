#!/bin/bash
#############################################
# Cipi — the Deployer binary (/usr/local/bin/dep), pinned
#
# Up to 5.9.1 setup.sh downloaded https://deployer.org/deployer.phar, which
# now serves Deployer 6.8.0: no `deploy:publish`, so every deploy of a fresh
# server failed with "Task `deploy:publish` not found" (#519). The phar now
# comes from Deployer's GitHub release, a version Cipi's recipes are written
# for, checked against the SHA-256 GitHub publishes for that asset, and asked
# its version before it replaces anything.
#
# Sourced by setup.sh (before /opt/cipi exists, see _cipi_source_lib) and by
# migrations. No dependency on common.sh.
#############################################

CIPI_DEPLOYER_VERSION="8.0.5"
CIPI_DEPLOYER_SHA256="0026dfa73626a8ccde06222fe5fccf03e6d4a19e765914bb87d7d2cc21f3e57d"
[[ -z "${CIPI_DEPLOYER_URL:-}" ]] && \
    CIPI_DEPLOYER_URL="https://github.com/deployphp/deployer/releases/download/v${CIPI_DEPLOYER_VERSION}/deployer.phar"

# The version a phar reports ("8.0.5"), run with the server's PHP.
cipi_deployer_phar_version() {   # <phar>
    local php; php=$(command -v php 2>/dev/null || true)
    [[ -n "$php" ]] || return 1
    "$php" "$1" --version 2>/dev/null < /dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1
}

# Installs the pinned Deployer at <dest> (default /usr/local/bin/dep).
# 0 on success; 1 with the reason on stderr, and <dest> untouched.
cipi_deployer_install() {   # [dest]
    local dest="${1:-/usr/local/bin/dep}" tmp sum v
    tmp=$(mktemp) || return 1
    if ! curl -fsSL --max-time 180 -o "$tmp" "$CIPI_DEPLOYER_URL"; then
        rm -f "$tmp"
        echo "Deployer ${CIPI_DEPLOYER_VERSION}: download failed (${CIPI_DEPLOYER_URL})" >&2
        return 1
    fi
    sum=$(sha256sum "$tmp" | awk '{ print $1 }')
    if [[ "$sum" != "$CIPI_DEPLOYER_SHA256" ]]; then
        rm -f "$tmp"
        echo "Deployer ${CIPI_DEPLOYER_VERSION}: the download does not match its SHA-256 — not installed" >&2
        return 1
    fi
    v=$(cipi_deployer_phar_version "$tmp" || true)
    if [[ "${v%%.*}" != "${CIPI_DEPLOYER_VERSION%%.*}" ]]; then
        rm -f "$tmp"
        echo "Deployer ${CIPI_DEPLOYER_VERSION}: the phar reports version '${v:-none}' — not installed" >&2
        return 1
    fi
    if ! install -m 755 "$tmp" "$dest"; then
        rm -f "$tmp"
        echo "Deployer: could not write ${dest}" >&2
        return 1
    fi
    rm -f "$tmp"
    return 0
}
