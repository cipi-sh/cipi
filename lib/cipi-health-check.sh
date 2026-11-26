#!/bin/bash
#############################################
# Cipi — cron helper: probe configured health URLs
# Debounce: notify only when failing 3 consecutive runs (~15 min).
#############################################
set -euo pipefail

CIPI_LIB="${CIPI_LIB:-/opt/cipi/lib}"
CIPI_CONFIG="${CIPI_CONFIG:-/etc/cipi}"
CIPI_LOG="${CIPI_LOG:-/var/log/cipi}"
STATE_DIR="${CIPI_LOG}/health"
mkdir -p "$STATE_DIR"

# shellcheck source=/dev/null
source "${CIPI_LIB}/common.sh"
# shellcheck source=/dev/null
source "${CIPI_LIB}/smtp.sh" 2>/dev/null || true

json=$(vault_read apps.json 2>/dev/null || echo '{}')
echo "$json" | jq -r 'to_entries[] | select(.value.health_url != null and (.value.health_url|tostring|length) > 0) | "\(.key)\t\(.value.health_url)\t\(.value.health_expect // "200")"' \
| while IFS=$'\t' read -r app url expect; do
    [[ -z "$app" || -z "$url" ]] && continue
    [[ -z "$expect" ]] && expect=200
    # curl already writes "000" through -w on a connection failure; an
    # `|| echo 000` fallback would append a second one ("000000").
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -L "$url" 2>/dev/null) || true
    [[ "$code" =~ ^[0-9]{3}$ ]] || code="000"
    failfile="${STATE_DIR}/${app}.failcount"
    statefile="${STATE_DIR}/${app}.state"
    if [[ "$code" == "$expect" ]]; then
        echo "ok" > "$statefile"
        echo "0" > "$failfile"
        continue
    fi
    count=0
    [[ -f "$failfile" ]] && count=$(cat "$failfile" 2>/dev/null || echo 0)
    count=$((count + 1))
    echo "$count" > "$failfile"
    echo "fail:${code}" > "$statefile"
    # Notify on 3rd consecutive failure only (debounce)
    if [[ "$count" -eq 3 ]] && type cipi_notify &>/dev/null; then
        cipi_notify \
            "Cipi healthcheck failed: ${app} on $(hostname)" \
            "HTTP healthcheck failed 3 consecutive times.\n\nServer: $(hostname)\nApp: ${app}\nURL: ${url}\nExpected: ${expect}\nGot: ${code}\nTime: $(notify_now)" \
            health_fail
    fi
done
