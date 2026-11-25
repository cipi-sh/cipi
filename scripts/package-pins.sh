#!/bin/bash
#############################################
# Cipi — refresh and check the pins of the upstream package entries
#
# lib/package.sh installs a few tools Ubuntu does not ship (the scanners of
# Hackly: nuclei, OWASP ZAP, Nikto, Trivy…) from upstream, and only the bytes
# pinned in its _pkg_pins table: the SHA-256 of each download, or for a git
# tag the commit it points to. This script is how those pins are made, by a
# maintainer, at release time — never on a server.
#
#   scripts/package-pins.sh                 compare the pins with upstream
#   scripts/package-pins.sh --write         fill empty pins, fix wrong ones
#   scripts/package-pins.sh --download      also download every file and hash
#                                           it here (the strongest check)
#
# Where each hash comes from:
#   sec-nuclei  nuclei_<v>_checksums.txt of the GitHub release
#   sec-trivy   trivy_<v>_checksums.txt of the GitHub release
#   sec-zap     ZapVersions.xml of zaproxy/zap-admin (the ZAP release manifest)
#   sec-nikto   git ls-remote: the commit of the tag
#
# A version bump is an edit to _pkg_upstream (the version) and _pkg_pins (the
# URLs), then --write, then tests/verify-5.14.0.sh. Needs curl, git, awk.
#############################################
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="${ROOT}/lib/package.sh"
WRITE=false; DOWNLOAD=false
for a in "$@"; do
    case "$a" in
        --write) WRITE=true ;;
        --download) DOWNLOAD=true ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done

fetch() { curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 3 --connect-timeout 20 "$1"; }

# shellcheck disable=SC1090
source <(sed -n '/^_pkg_upstream()/,/^}/p; /^_pkg_pins()/,/^}/p' "$PKG")
version_of() { _pkg_upstream | awk -F'|' -v i="$1" '$1 == i { print $3; exit }'; }

# Where upstream publishes the hash of one pin line.
source_of() {
    local id="$1" arch="$2" v="$4"
    case "$id" in
        sec-nuclei) echo "https://github.com/projectdiscovery/nuclei/releases/download/v${v}/nuclei_${v}_checksums.txt" ;;
        sec-zap)    echo "https://raw.githubusercontent.com/zaproxy/zap-admin/master/ZapVersions.xml" ;;
        sec-trivy)  echo "https://github.com/aquasecurity/trivy/releases/download/v${v}/trivy_${v}_checksums.txt" ;;
        sec-nikto)  echo "$3" ;;
    esac
}

# The hash upstream publishes for one pin line. Returns 2 when its source
# cannot be reached: that is not "no hash".
upstream_hash() {
    local id="$1" arch="$2" url="$3" v="$4" file="${3##*/}" src body
    src=$(source_of "$@")
    if [[ "$id" == sec-nikto ]]; then
        body=$(git ls-remote "$url" "refs/tags/${v}^{}" "refs/tags/${v}" 2>/dev/null) || return 2
        awk '{ h[$2] = $1 } END { for (r in h) if (r ~ /\^\{\}$/) { print h[r]; exit } for (r in h) { print h[r]; exit } }' <<< "$body"
        return 0
    fi
    body=$(fetch "$src" 2>/dev/null) || return 2
    case "$id" in
        sec-nuclei|sec-trivy) awk -v f="$file" '$2 == f { print $1 }' <<< "$body" ;;
        sec-zap)    awk -v f="$file" 'index($0, "<file>" f "</file>") { hit = 1; next }
                        hit && /<hash>/ { sub(/.*SHA-256:/, ""); sub(/<.*/, ""); print; exit }' <<< "$body" ;;
    esac
}

changed=0; problems=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cp "$PKG" "${tmp}/package.sh"

while IFS='|' read -r id arch url pinned; do
    [[ -z "$id" ]] && continue
    v=$(version_of "$id")
    if [[ "$url" != *"$v"* && "$id" != sec-nikto ]]; then
        echo "✗ ${id}/${arch}: the URL does not name the pinned version ${v}: ${url}"; problems=$((problems + 1)); continue
    fi
    rc=0; got=$(upstream_hash "$id" "$arch" "$url" "$v") || rc=$?
    if [[ $rc -eq 2 ]]; then
        echo "? ${id}/${arch}: cannot reach $(source_of "$id" "$arch" "$url" "$v") — pin not checked"; problems=$((problems + 1)); continue
    fi
    if [[ -z "$got" ]]; then
        echo "✗ ${id}/${arch}: upstream publishes no hash for ${url##*/} ${v}"; problems=$((problems + 1)); continue
    fi
    if $DOWNLOAD && [[ "$id" != sec-nikto ]]; then
        echo "  downloading ${url##*/}…"
        fetch "$url" > "${tmp}/dl"
        real=$(sha256sum "${tmp}/dl" | cut -c1-64)
        if [[ "$real" != "$got" ]]; then
            echo "✗ ${id}/${arch}: the file hashes to ${real}, upstream says ${got}"; problems=$((problems + 1)); continue
        fi
    fi
    if [[ "$pinned" == "$got" ]]; then
        echo "✓ ${id}/${arch} ${v}  ${got}"
        continue
    fi
    echo "${pinned:+✗}${pinned:-+} ${id}/${arch} ${v}  pinned ${pinned:-(none)}, upstream ${got}"
    changed=$((changed + 1))
    # Only the line of this pin, inside _pkg_pins.
    awk -v l="${id}|${arch}|${url}|${pinned}" -v n="${id}|${arch}|${url}|${got}" \
        '$0 == l && !done { print n; done = 1; next } { print }' "${tmp}/package.sh" > "${tmp}/next" && mv "${tmp}/next" "${tmp}/package.sh"
done <<< "$(_pkg_pins)"

if [[ $changed -gt 0 ]]; then
    if $WRITE; then
        cp "${tmp}/package.sh" "$PKG"
        echo ""; echo "${changed} pin(s) written to lib/package.sh — run tests/verify-5.14.0.sh and commit."
    else
        echo ""; echo "${changed} pin(s) differ from upstream: --write updates lib/package.sh."
    fi
fi
[[ $problems -eq 0 ]] || { echo ""; echo "${problems} problem(s) above."; exit 1; }
