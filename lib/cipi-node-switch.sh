#!/bin/bash
#############################################
# Cipi — Blue/green switch for Node SSR apps (root)
#
# Called by the app's Deployer recipe (sudo) right before `current` moves, by
# the recipe after a rollback, and by `cipi node restart`:
#
#   1. start the release on the idle slot (blue ⇄ green, each its own
#      Supervisor program and localhost port);
#   2. wait until it answers on the health path — any status below 500;
#   3. point the nginx upstream at it (nginx -t, then reload);
#   4. give in-flight requests a moment, then stop the old slot.
#
# If the new process never answers, it is stopped and the old slot keeps
# serving: the deploy fails with nothing published. Nothing here trusts the
# caller beyond the release path, which must be a release of this app. The
# rest (ports, start command, Node version, health path) comes from
# /var/lib/cipi/node/<app>.json, which only root writes.
#
# Usage: cipi-node-switch <app> <release-dir|current>
#        cipi-node-switch <app> --stop | --status        (root only)
#############################################
set -uo pipefail
umask 022
export LC_ALL=C

APP="${1:-}"; TARGET="${2:-}"
[[ "$APP" =~ ^[a-z][a-z0-9]{2,31}$ ]] || { echo "cipi-node-switch: invalid app name" >&2; exit 2; }
[[ "$(id -u)" -eq 0 ]] || { echo "cipi-node-switch: must run as root" >&2; exit 2; }
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    [[ "$SUDO_USER" == "$APP" ]] || { echo "cipi-node-switch: ${SUDO_USER} cannot manage ${APP}" >&2; exit 2; }
    [[ "$TARGET" == --* ]] && { echo "cipi-node-switch: ${TARGET} is root only" >&2; exit 2; }
fi

STATE="/var/lib/cipi/node/${APP}.json"
[[ -f "$STATE" ]] || { echo "cipi-node-switch: ${APP} is not a Node app (no ${STATE})" >&2; exit 2; }
HOME_DIR="/home/${APP}"
SUP_CONF="/etc/supervisor/conf.d/${APP}-node.conf"
UPSTREAM="/etc/nginx/conf.d/cipi-node-${APP}.conf"
SLOTS=(blue green)

st() { jq -r "$1" "$STATE"; }
say() { printf '[cipi-node] %s\n' "$*"; }

MODE=$(st '.mode // "ssr"')
if [[ "$MODE" != "ssr" ]]; then
    [[ "$TARGET" == "--status" ]] && { echo "${APP}: ${MODE} app — no Node process"; exit 0; }
    exit 0
fi

VERSION=$(st '.version'); START=$(st '.start'); HEALTH=$(st '.health // "/"')
TIMEOUT=$(st '.health_timeout // 60'); DOMAIN=$(st '.domain // ""')
PORTS=( "$(st '.ports[0]')" "$(st '.ports[1]')" )
[[ "$VERSION" =~ ^[0-9]{2}$ ]] || { echo "cipi-node-switch: bad Node version in state" >&2; exit 1; }
[[ "${PORTS[0]}" =~ ^[0-9]+$ && "${PORTS[1]}" =~ ^[0-9]+$ ]] || { echo "cipi-node-switch: bad ports in state" >&2; exit 1; }
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || TIMEOUT=60
NODE_BIN="/opt/cipi/node/${VERSION}/bin"

exec 9>"/run/lock/cipi-node-${APP}.lock"
flock -w 900 9 || { echo "cipi-node-switch: another switch is still running" >&2; exit 1; }

prog() { printf '%s-node-%s' "$APP" "${SLOTS[$1]}"; }
prog_state() { supervisorctl status "$(prog "$1")" 2>/dev/null | awk '{print $2}'; }

# Both [program] sections from the state file plus the overrides given:
# $1/$2 = release dir for blue/green, $3/$4 = autostart for blue/green.
write_conf() {
    local tmp i dir auto
    tmp=$(mktemp)
    for i in 0 1; do
        if [[ $i -eq 0 ]]; then dir="$1"; auto="$3"; else dir="$2"; auto="$4"; fi
        [[ -n "$dir" ]] || continue
        cat >> "$tmp" <<EOF
[program:$(prog "$i")]
command=/usr/local/bin/cipi-node-run ${APP}
directory=${dir}
user=${APP}
environment=HOME="${HOME_DIR}",PORT="${PORTS[$i]}",NODE_ENV="production",PATH="${NODE_BIN}:/usr/local/bin:/usr/bin:/bin",CIPI_NODE_START="${START}"
autostart=${auto}
autorestart=true
startsecs=2
startretries=3
stopsignal=TERM
stopwaitsecs=30
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=${HOME_DIR}/logs/node-${SLOTS[$i]}.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3

EOF
    done
    mv -f "$tmp" "$SUP_CONF"
    chmod 644 "$SUP_CONF"
}

write_upstream() {
    local tmp; tmp=$(mktemp)
    printf 'upstream cipi_node_%s {\n    server 127.0.0.1:%s;\n    keepalive 16;\n}\n' "$APP" "$1" > "$tmp"
    mv -f "$tmp" "$UPSTREAM"
    chmod 644 "$UPSTREAM"
}

ACTIVE=$(st '.active // -1')
REL=( "$(st '.releases[0] // ""')" "$(st '.releases[1] // ""')" )
AUTO=( false false )
[[ "$ACTIVE" == 0 || "$ACTIVE" == 1 ]] && AUTO[$ACTIVE]=true

case "$TARGET" in
    --status)
        for i in 0 1; do
            printf '%-6s port %-5s %-9s %s%s\n' "${SLOTS[$i]}" "${PORTS[$i]}" "$(prog_state "$i" || echo -)" \
                "${REL[$i]:--}" "$([[ "$ACTIVE" == "$i" ]] && echo '  ← serving')"
        done
        exit 0 ;;
    --stop)
        for i in 0 1; do supervisorctl stop "$(prog "$i")" >/dev/null 2>&1 || true; done
        exit 0 ;;
    current)
        TARGET=$(readlink -f "${HOME_DIR}/current" 2>/dev/null || true) ;;
esac

TARGET=$(realpath -e "$TARGET" 2>/dev/null || true)
[[ "$TARGET" =~ ^/home/${APP}/releases/[0-9]+$ && -d "$TARGET" ]] \
    || { echo "cipi-node-switch: not a release of ${APP}: ${2:-}" >&2; exit 2; }
[[ -x "${NODE_BIN}/node" ]] || { echo "cipi-node-switch: Node ${VERSION} is not installed (cipi node install ${VERSION})" >&2; exit 1; }

NEXT=0
[[ "$ACTIVE" == 0 ]] && NEXT=1
say "starting release $(basename "$TARGET") on ${SLOTS[$NEXT]} (127.0.0.1:${PORTS[$NEXT]})"

# Something left on the idle port (a crashed switch, a manual start) would
# answer the health check instead of the new release.
supervisorctl stop "$(prog "$NEXT")" >/dev/null 2>&1 || true
if ss -ltn 2>/dev/null | grep -qE "127\.0\.0\.1:${PORTS[$NEXT]}\s|\*:${PORTS[$NEXT]}\s|:::${PORTS[$NEXT]}\s"; then
    echo "cipi-node-switch: port ${PORTS[$NEXT]} is already in use by another process" >&2
    exit 1
fi

new_rel=( "${REL[0]}" "${REL[1]}" ); new_rel[$NEXT]="$TARGET"
new_auto=( "${AUTO[0]}" "${AUTO[1]}" ); new_auto[$NEXT]=true
write_conf "${new_rel[0]}" "${new_rel[1]}" "${new_auto[0]}" "${new_auto[1]}"
supervisorctl reread >/dev/null 2>&1 || true
supervisorctl update "$(prog "$NEXT")" >/dev/null 2>&1 || true
case "$(prog_state "$NEXT")" in
    RUNNING|STARTING) ;;
    *) supervisorctl start "$(prog "$NEXT")" >/dev/null 2>&1 || true ;;
esac

fail_new() {
    echo "cipi-node-switch: $1 — the previous release keeps serving" >&2
    echo "---- last lines of ${HOME_DIR}/logs/node-${SLOTS[$NEXT]}.log ----" >&2
    tail -n 30 "${HOME_DIR}/logs/node-${SLOTS[$NEXT]}.log" >&2 2>/dev/null || true
    supervisorctl stop "$(prog "$NEXT")" >/dev/null 2>&1 || true
    write_conf "${REL[0]}" "${REL[1]}" "${AUTO[0]}" "${AUTO[1]}"
    supervisorctl reread >/dev/null 2>&1 || true
    supervisorctl update "$(prog "$NEXT")" >/dev/null 2>&1 || true
    exit 1
}

deadline=$((SECONDS + TIMEOUT)) code="000"
while (( SECONDS < deadline )); do
    case "$(prog_state "$NEXT")" in
        FATAL|EXITED|BACKOFF) fail_new "the process did not stay up ($(prog_state "$NEXT"))" ;;
    esac
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        ${DOMAIN:+-H "Host: ${DOMAIN}"} -H 'X-Forwarded-Proto: https' \
        "http://127.0.0.1:${PORTS[$NEXT]}${HEALTH}" 2>/dev/null || true)
    [[ "$code" =~ ^[1-4][0-9][0-9]$ ]] && break
    sleep 1
done
[[ "$code" =~ ^[1-4][0-9][0-9]$ ]] || fail_new "no answer below 500 on ${HEALTH} within ${TIMEOUT}s (last: ${code})"
say "healthy on ${SLOTS[$NEXT]} (HTTP ${code} on ${HEALTH})"

PREV_UPSTREAM=""
[[ -f "$UPSTREAM" ]] && PREV_UPSTREAM=$(cat "$UPSTREAM")
write_upstream "${PORTS[$NEXT]}"
if ! nginx -t >/dev/null 2>&1 || ! systemctl reload nginx >/dev/null 2>&1; then
    if [[ -n "$PREV_UPSTREAM" ]]; then printf '%s\n' "$PREV_UPSTREAM" > "$UPSTREAM"; else rm -f "$UPSTREAM"; fi
    systemctl reload nginx >/dev/null 2>&1 || true
    fail_new "nginx refused the switch"
fi
say "nginx now proxies to ${SLOTS[$NEXT]}"

tmp=$(mktemp)
jq --argjson a "$NEXT" --arg r0 "${new_rel[0]}" --arg r1 "${new_rel[1]}" --arg t "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '.active = $a | .releases = [$r0, $r1] | .switched_at = $t' "$STATE" > "$tmp" && mv -f "$tmp" "$STATE"
chmod 600 "$STATE"

if [[ "$ACTIVE" == 0 || "$ACTIVE" == 1 ]]; then
    sleep "$(st '.drain // 5')"
    supervisorctl stop "$(prog "$ACTIVE")" >/dev/null 2>&1 || true
    final_auto=( false false ); final_auto[$NEXT]=true
    write_conf "${new_rel[0]}" "${new_rel[1]}" "${final_auto[0]}" "${final_auto[1]}"
    supervisorctl reread >/dev/null 2>&1 || true
    supervisorctl update "$(prog "$ACTIVE")" >/dev/null 2>&1 || true
    say "stopped ${SLOTS[$ACTIVE]}"
fi
exit 0
