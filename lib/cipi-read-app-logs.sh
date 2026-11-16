#!/bin/bash
# Paginated app log read for the Cipi panel API (replaces sudo bash for log tailing).
# Usage: cipi-read-app-logs <glob-pattern> <page> <per_page>
#
# Root, called by the panel (www-data, through sudo) with a pattern under an
# app's home. That directory belongs to the app user: read as root, a symlink
# there called x.log showed any file of the server to whoever may read that
# app's logs in the panel — and the pattern itself, checked only at its start,
# could walk out with "..", or carry a second path after a space. Since 5.9.0
# the files are read as the app user: a link, a "..", whatever the pattern
# matches, gives nothing the app could not read already. The logs root writes
# (nginx, supervisor, deploy.log) are in /var/log/cipi-apps/<app> and are
# reached through the symlinks in ~/logs.
set -euo pipefail

pattern="${1:?pattern required}"
page="${2:-1}"
per_page="${3:-50}"

if [[ ! "$pattern" =~ ^/home/([a-z][a-z0-9]*)/(logs/|shared/storage/logs/) ]]; then
    exit 1
fi
app="${BASH_REMATCH[1]}"

# One glob, no way out of the directory.
if [[ "$pattern" =~ [[:space:]] || "$pattern" == *..* ]]; then
    exit 1
fi

if ! [[ "$page" =~ ^[0-9]{1,6}$ && "$per_page" =~ ^[0-9]{1,6}$ ]]; then
    exit 1
fi

id "$app" &>/dev/null || exit 1

cd /
exec sudo -u "$app" /bin/bash -c '
    shopt -s nullglob
    for f in $1; do
        [[ -f "$f" && -r "$f" ]] || continue
        total=$(wc -l < "$f" | tr -d " \n")
        echo "===CIPI_LOG_FILE:${f}:${total}==="
        /usr/bin/tail -n "$(( $2 * $3 ))" "$f" | /usr/bin/head -n "$3"
        echo "===CIPI_LOG_END==="
    done' _ "$pattern" "$page" "$per_page"
