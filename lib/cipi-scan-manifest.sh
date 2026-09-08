#!/bin/bash
#############################################
# Cipi — write an integrity manifest for one app
#
# Root only, and the manifest lives OUTSIDE the app tree
# (/var/lib/cipi/manifests, root:root 0600). A manifest sitting in
# /home/<app>/shared is writable by the app user, and open_basedir gives
# PHP that whole home — so the webshell the check exists to catch could
# rewrite its own baseline and the nightly run reported "clean".
#
# The webhook deploy runs from the app user's crontab, so it reaches this
# through one narrow sudoers entry that pins the app name:
#   <app> ALL=(root) NOPASSWD: /usr/local/bin/cipi-scan-manifest <app>
# That entry still lets a compromised app re-baseline itself, so every
# write is recorded in /var/log/cipi/events.log: a re-baseline with no
# deploy next to it is the thing to look for.
#
# Hashes regular files under current/ or htdocs/; does not follow the
# shared symlinks, so storage/.env changes are not in the manifest.
#############################################
set -euo pipefail

MANIFEST_DIR="/var/lib/cipi/manifests"
LOG_DIR="/var/log/cipi"

[[ $# -eq 1 ]] || { echo "Usage: cipi-scan-manifest <app>" >&2; exit 2; }
APP="$1"
[[ "$APP" =~ ^[a-z][a-z0-9]{2,31}$ ]] || { echo "cipi-scan-manifest: bad app name" >&2; exit 2; }
[[ "$(id -u)" -eq 0 ]] || { echo "cipi-scan-manifest: must run as root (sudo)" >&2; exit 2; }

HOME_DIR="/home/${APP}"
[[ -d "$HOME_DIR" ]] || exit 0

if [[ -d "${HOME_DIR}/current" ]]; then
    ROOT="${HOME_DIR}/current"
elif [[ -d "${HOME_DIR}/htdocs" ]]; then
    ROOT="${HOME_DIR}/htdocs"
else
    exit 0
fi

install -d -m 700 -o root -g root "$MANIFEST_DIR"
DEST="${MANIFEST_DIR}/${APP}.sha256"
TMP=$(mktemp "${MANIFEST_DIR}/.${APP}.XXXXXX")
ERR=$(mktemp)
trap 'rm -f "$TMP" "$ERR"' EXIT

{
    echo "# cipi integrity manifest  app=${APP}  $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "# root=${ROOT}  release=$(readlink -f "$ROOT" 2>/dev/null || echo "$ROOT")"
    echo "# symlinks not followed"
    (
        cd "$ROOT" || exit 1
        set -o pipefail
        find -P . -type f -print0 2>>"$ERR" | sort -z | xargs -0 -r sha256sum 2>>"$ERR"
    )
} > "$TMP"

# A pass that lost files would install a short baseline, and every file it lost
# would read as "extra" every night after that. Keep the previous manifest.
if [[ -s "$ERR" ]]; then
    echo "cipi-scan-manifest: could not hash every file under ${ROOT} — manifest unchanged" >&2
    head -5 "$ERR" >&2
    exit 1
fi

install -m 600 -o root -g root "$TMP" "$DEST"

mkdir -p "$LOG_DIR" 2>/dev/null || true
printf '[%s] [local] [key:n/a] scan manifest rewritten app=%s root=%s lines=%s invoked_by=%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$APP" "$ROOT" \
    "$(wc -l < "$DEST" | tr -d ' ')" "${SUDO_USER:-root}" \
    >> "${LOG_DIR}/events.log" 2>/dev/null || true
exit 0
