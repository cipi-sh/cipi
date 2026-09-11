#!/bin/bash
# Local regression checks for 5.3.0 — Cloudflare Zero Trust (opt-in),
# system monitor (cipi monitor) + alert channels (Slack/Discord/ntfy/webhook).
# Run from repo root: bash tests/verify-5.3.0.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

code_grep() {
    local pat="$1"; shift
    local f found=1
    for f in "$@"; do
        if grep -nE "$pat" "$f" 2>/dev/null \
            | grep -vE '^[0-9]+:[[:space:]]*#' \
            | sed "s|^|${f}:|" | grep . ; then
            found=0
        fi
    done
    return $found
}

echo "=== Cipi 5.3.0 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.3.0" ]] \
    && pass "version.md is 5.3.0" || fail "version.md is not 5.3.0"
grep -q '^## \[5.3.0\]' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.3.0 entry" || fail "CHANGELOG has no 5.3.0 entry"
[[ -f "${LIB}/migrations/5.3.0.sh" ]] \
    && pass "5.3.0 migration present" || fail "missing 5.3.0 migration"
[[ -f "${LIB}/zt.sh" ]] \
    && pass "lib/zt.sh present" || fail "missing lib/zt.sh"
[[ -f "${LIB}/monitor.sh" ]] \
    && pass "lib/monitor.sh present" || fail "missing lib/monitor.sh"
[[ -f "${LIB}/alerts.sh" ]] \
    && pass "lib/alerts.sh present" || fail "missing lib/alerts.sh"
[[ -f "${LIB}/cipi-monitor.sh" ]] \
    && pass "lib/cipi-monitor.sh helper present" || fail "missing lib/cipi-monitor.sh"
[[ ! -f "${LIB}/migrations/5.3.1.sh" ]] \
    && pass "no stray 5.3.1 migration" || fail "stray 5.3.1 migration"
[[ ! -f "${LIB}/migrations/5.4.0.sh" ]] \
    && pass "no stray 5.4.0 migration" || fail "stray 5.4.0 migration"

echo "-- syntax"
for f in "${ROOT}/cipi" "${LIB}/zt.sh" "${LIB}/ssl.sh" "${LIB}/crowdsec.sh" \
         "${LIB}/self-update.sh" "${LIB}/completion.sh" "${LIB}/service.sh" \
         "${LIB}/cipi-api-sudoers.sh" "${LIB}/notifications.sh" \
         "${LIB}/monitor.sh" "${LIB}/alerts.sh" "${LIB}/cipi-monitor.sh" \
         "${LIB}/smtp.sh" "${LIB}/common.sh" \
         "${LIB}/migrations/5.3.0.sh"; do
    if bash -n "$f" 2>/dev/null; then
        pass "syntax $(basename "$f")"
    else
        fail "syntax $(basename "$f")"
        bash -n "$f" || true
    fi
done

echo "-- dispatch / help / completion (zt)"
grep -q 'zt_command' "${ROOT}/cipi" && pass "cipi dispatches zt" || fail "no zt dispatch"
grep -q 'source "${CIPI_LIB}/zt.sh"' "${ROOT}/cipi" && pass "cipi sources zt.sh" || fail "cipi does not source zt.sh"
grep -q '_help_cmd "cipi zt' "${ROOT}/cipi" && pass "top-level help mentions cipi zt" || fail "help omits cipi zt"
grep -q 'zt|zerotrust|zero-trust|cloudflare|tunnel)' "${ROOT}/cipi" \
    && pass "help topic aliases include zt" || fail "no zt help topic"
grep -q 'show_help_topic zt' "${ROOT}/cipi" && pass "help all includes zt" || fail "help all omits zt"

echo "-- dispatch / help / completion (monitor)"
grep -q 'monitor_command' "${ROOT}/cipi" && pass "cipi dispatches monitor" || fail "no monitor dispatch"
grep -q 'source "${CIPI_LIB}/monitor.sh"' "${ROOT}/cipi" && pass "cipi sources monitor.sh" || fail "cipi does not source monitor.sh"
grep -q '_help_cmd "cipi monitor' "${ROOT}/cipi" && pass "top-level help mentions cipi monitor" || fail "help omits cipi monitor"
grep -q 'show_help_topic monitor' "${ROOT}/cipi" && pass "help all includes monitor" || fail "help all omits monitor"
grep -q ' monitor ' <<< "$(sed -n '/_help_topics_list()/,/^EOF/p' "${ROOT}/cipi")" \
    && pass "monitor is in the help topics list" || fail "monitor missing from topics list"

adv=$(sed -n 's/.*local commands="\([^"]*\)".*/\1/p' "${LIB}/completion.sh" | head -1)
[[ "$adv" == *' zt '* ]] || [[ "$adv" == zt' '* ]] || [[ "$adv" == *' zt' ]] \
    && pass "completion advertises zt" || fail "completion omits zt"
[[ "$adv" == *' monitor '* ]] && pass "completion advertises monitor" || fail "completion omits monitor"
topics=$(sed -n 's/.*local topics="\([^"]*\)".*/\1/p' "${LIB}/completion.sh" | head -1)
[[ "$topics" == *' zt '* ]] && pass "help topics include zt" || fail "help topics omit zt"
[[ "$topics" == *' monitor '* ]] && pass "help topics include monitor" || fail "help topics omit monitor"

miss=""
for v in $adv; do
    [[ "$v" == "help" || "$v" == "completion" ]] && continue
    grep -qE "^[[:space:]]+${v}[)|]" "${ROOT}/cipi" || miss="$miss $v"
done
[[ -z "$miss" ]] && pass "completion verbs all dispatch in cipi" \
    || fail "completion advertises verbs cipi does not dispatch:$miss"

echo "-- as-is: setup.sh / self-update / migration never enable this"
if code_grep 'cloudflared|cipi zt enable' "${ROOT}/setup.sh"; then
    fail "setup.sh would install cloudflared or enable zt"
else
    pass "setup.sh does not install cloudflared or enable zt"
fi
if code_grep 'cipi zt enable|apt-get install.*cloudflared|cloudflared service' \
        "${LIB}/self-update.sh"; then
    fail "self-update would enable zt or install cloudflared"
else
    pass "self-update does not enable zt or install cloudflared"
fi
if code_grep 'zt enable|cloudflared' "${LIB}/migrations/5.3.0.sh"; then
    fail "migration 5.3.0 installs or enables Zero Trust"
else
    pass "migration does not enable zt or mention cloudflared in code"
fi
if code_grep 'hooks.slack.com|discord.com/api/webhooks|ntfy.sh' "${LIB}/migrations/5.3.0.sh"; then
    fail "migration 5.3.0 would configure a channel"
else
    pass "migration does not configure any channel"
fi
if code_grep '_notify_set_trigger|disable-all' "${LIB}/migrations/5.3.0.sh"; then
    fail "migration 5.3.0 would change notification triggers"
else
    pass "migration does not touch notification triggers"
fi
grep -q '_mon_ensure_cron' "${LIB}/migrations/5.3.0.sh" \
    && pass "migration installs the monitor cron" || fail "migration omits cron install"

echo "-- lock ssh is lockout-safe"
if awk '/^_zt_lock_ssh\(\)/,/^_zt_unlock_http_apply\(\)/' "${LIB}/zt.sh" \
        | grep -q '_zt_tunnel_healthy'; then
    pass "lock ssh requires _zt_tunnel_healthy"
else
    fail "lock ssh does not check tunnel health"
fi
if awk '/^_zt_lock_ssh\(\)/,/^_zt_unlock_http_apply\(\)/' "${LIB}/zt.sh" \
        | grep -q '_zt_ssh_ingress_present'; then
    pass "lock ssh requires SSH ingress"
else
    fail "lock ssh does not require SSH ingress"
fi
if awk '/^_zt_enable\(\)/,/^_zt_disable\(\)/' "${LIB}/zt.sh" | grep -q 'ufw delete allow 22'; then
    fail "enable would close port 22"
else
    pass "enable does not close port 22"
fi
grep -q 'cipi zt ssh unlock' "${LIB}/zt.sh" \
    && pass "ssh unlock is documented in zt.sh" || fail "no ssh unlock"

echo "-- real_ip / webhook / HTTP-01"
grep -q 'CF-Connecting-IP' "${LIB}/zt.sh" \
    && pass "real_ip uses CF-Connecting-IP" || fail "no CF-Connecting-IP"
grep -q 'real_ip_header CF-Connecting-IP' "${LIB}/zt.sh" \
    && pass "nginx real_ip_header is CF-Connecting-IP" || fail "real_ip_header missing"
grep -q '/cipi/webhook' "${LIB}/zt.sh" \
    && pass "Access webhook bypass path is named" || fail "no /cipi/webhook bypass"
grep -q '_zt_access_policy "$wid" "bypass"' "${LIB}/zt.sh" \
    && pass "webhook Access policy is bypass" || fail "webhook policy is not bypass"
grep -q '_ssl_zt_lock_http' "${LIB}/ssl.sh" \
    && pass "ssl.sh checks zt lock http" || fail "ssl.sh ignores lock http"
grep -q 'ssl_origin_ca' "${LIB}/ssl.sh" \
    && pass "HTTP-01 refuses Origin CA apps" || fail "HTTP-01 can overwrite Origin CA"
grep -q '_ssl_certbot_redirect_flag' "${LIB}/ssl.sh" \
    && pass "tunneled apps skip certbot --redirect" || fail "no --no-redirect for tunneled apps"
grep -q 'cipi zt enable' "${LIB}/crowdsec.sh" \
    && pass "CrowdSec real_ip error points at cipi zt enable" || fail "CrowdSec error omits zt"

echo "-- sudoers: status/list only"
grep -q 'cipi zt status' "${LIB}/cipi-api-sudoers.sh" \
    && pass "sudoers allows zt status" || fail "sudoers omits zt status"
if grep -q 'cipi zt enable' "${LIB}/cipi-api-sudoers.sh"; then
    fail "sudoers would allow zt enable"
else
    pass "sudoers does not allow zt enable"
fi
grep -q 'cipi monitor list' "${LIB}/cipi-api-sudoers.sh" \
    && pass "sudoers allows monitor list" || fail "sudoers omits monitor list"
if grep -qE 'cipi monitor (set|enable|disable|run)' "${LIB}/cipi-api-sudoers.sh"; then
    fail "sudoers would allow monitor mutations from the panel"
else
    pass "sudoers does not allow monitor mutations"
fi

echo "-- service + notifications"
grep -q 'cloudflared' "${LIB}/service.sh" \
    && pass "service.sh knows cloudflared" || fail "service.sh omits cloudflared"
grep -q 'zt_enable|' "${LIB}/notifications.sh" \
    && pass "notification catalog has zt_enable" || fail "no zt_enable trigger"
grep -q 'zt_lock_ssh|' "${LIB}/notifications.sh" \
    && pass "notification catalog has zt_lock_ssh" || fail "no zt_lock_ssh trigger"
grep -q "monitor_ok|" "${LIB}/notifications.sh" \
    && pass "notification catalog has monitor_ok" || fail "no monitor_ok trigger"
# _mon_apply_state emits "monitor_<check id>". Every one of those must be a
# registered trigger, or `cipi notifications disable` rejects it as unknown and
# the alert can never be muted. Derive both lists instead of hard-coding them.
for c in $(sed -n '/_mon_catalog() {/,/^EOF/p' "${LIB}/monitor.sh" | grep '|' | cut -d'|' -f1); do
    grep -q "^monitor_${c}|" "${LIB}/notifications.sh" \
        && pass "check '${c}' emits registered trigger monitor_${c}" \
        || fail "check '${c}' emits monitor_${c}, which is not in the trigger catalog"
    grep -q "monitor_${c}" "${LIB}/alerts.sh" \
        || pass "monitor_${c} is not flagged urgent for ntfy (fine)"
done
# Nothing may reference the old singular names.
if grep -rn 'monitor_service\b\|monitor_worker\b' "${LIB}" "${ROOT}/CHANGELOG.md" >/dev/null 2>&1; then
    fail "stale singular monitor_service / monitor_worker trigger name"
else
    pass "no stale singular monitor_service / monitor_worker names"
fi

echo "-- channels: fan-out from cipi_notify, all five types"
grep -q '_alerts_deliver' "${LIB}/smtp.sh" \
    && pass "cipi_notify fans out to channels" || fail "cipi_notify has no channel fan-out"
grep -q 'source "${CIPI_LIB}/alerts.sh"' "${LIB}/common.sh" \
    && pass "common.sh sources alerts.sh" || fail "common.sh does not source alerts.sh"
for type in slack discord ntfy telegram webhook; do
    grep -qE "^${type}\)|^        ${type}\)" "${LIB}/alerts.sh" \
        && pass "alerts.sh delivers to ${type}" || fail "alerts.sh cannot deliver to ${type}"
done
grep -q 'api.telegram.org/bot' "${LIB}/alerts.sh" \
    && pass "telegram delivers via Bot API sendMessage" || fail "no telegram Bot API endpoint"
grep -q '\-\-chat-id' "${LIB}/alerts.sh" \
    && pass "telegram channel takes --chat-id" || fail "telegram has no --chat-id"
grep -q 'alerts_channel_command' "${LIB}/notifications.sh" \
    && pass "notifications command routes 'channel'" || fail "no channel subcommand"

echo "-- monitor: checks, cron helper, alert semantics"
for fn in _mon_check_disk _mon_check_ssl _mon_check_services _mon_check_workers \
          _mon_check_http_5xx _mon_check_fs _mon_check_load _mon_run_all \
          _mon_apply_state _mon_ensure_cron monitor_command; do
    grep -qE "^${fn}\(\)" "${LIB}/monitor.sh" \
        && pass "monitor.sh defines ${fn}" || fail "monitor.sh missing ${fn}"
done
grep -q '/etc/cron.d/cipi-monitor' "${LIB}/monitor.sh" \
    && pass "monitor cron path is /etc/cron.d/cipi-monitor" || fail "no cron path"
grep -q 'source "${CIPI_LIB}/monitor.sh"' "${LIB}/cipi-monitor.sh" \
    && pass "cron helper sources monitor.sh" || fail "helper does not source monitor.sh"
grep -q '_mon_run_all true' "${LIB}/cipi-monitor.sh" \
    && pass "cron helper runs checks with alerting" || fail "helper does not alert"
grep -q 'monitor_ok' "${LIB}/monitor.sh" \
    && pass "recovery alerts use monitor_ok" || fail "no recovery alert"
grep -q 'reminder' "${LIB}/monitor.sh" \
    && pass "persisting failures have a reminder interval" || fail "no reminder logic"

echo "-- jq boolean defaults: '// true' must never guard an enabled flag"
if code_grep '\.enabled // true|\.triggers\[\$t\] // true|\.triggers\[\$trigger\] // true' \
    "${LIB}/alerts.sh" "${LIB}/monitor.sh" "${LIB}/notifications.sh"; then
    fail "jq '// true' on a boolean flag (false reads as enabled)"
else
    pass "boolean flags use '!= false' (disabled stays disabled)"
fi

if code_grep '\.tls // true|\.health\.enabled // true' "${LIB}/smtp.sh" "${LIB}/yml.sh"; then
    fail "jq '// true' still guards smtp tls / cipi.yml health.enabled"
else
    pass "smtp tls and cipi.yml health.enabled honour an explicit false"
fi

echo "-- install paths: the monitor cron must exist on fresh installs and upgrades"
grep -q '/etc/cron.d/cipi-monitor' "${ROOT}/setup.sh" \
    && pass "setup.sh installs the monitor cron" || fail "fresh installs get no monitor cron"
grep -q 'cp cipi-install/lib/cipi-monitor.sh /usr/local/bin/cipi-monitor' "${ROOT}/setup.sh" \
    && pass "setup.sh installs the monitor helper" || fail "setup.sh omits the monitor helper"
grep -q '/usr/local/bin/cipi-monitor' "${LIB}/self-update.sh" \
    && pass "self-update refreshes the monitor helper" || fail "self-update leaves a stale monitor helper"

echo "-- CLI contracts"
grep -q 'sub == --\*\|sub" == --\*' "${LIB}/monitor.sh" \
    && pass "cipi monitor --json runs checks (leading flag is not a subcommand)" \
    || fail "cipi monitor --json falls through to the usage error"
grep -qE '_mon_ensure_cron >&2' "${LIB}/monitor.sh" \
    && pass "--json stays machine-readable when the cron cannot be written" \
    || fail "warn() on stdout can corrupt cipi monitor --json"
[[ "$(grep -c 'cipi_notify .*>/dev/null\|"monitor_${id}" >/dev/null\|monitor_ok >/dev/null' "${LIB}/monitor.sh")" -ge 3 ]] \
    && pass "monitor alerts cannot leak stdout into the results JSON" \
    || fail "cipi_notify stdout can corrupt _mon_run_all output"
grep -q 'local w2=' "${LIB}/completion.sh" \
    && pass "completion defines w2 (channel add / monitor set complete)" \
    || fail "completion references w2 without defining it"
grep -q -- '--data-binary @-' "${LIB}/alerts.sh" \
    && pass "ntfy body goes in on stdin (a leading @ is not a filename)" \
    || fail "curl -d would read an @-prefixed alert body as a file"

echo "-- functions exist after source"
CIPI_CONFIG="/tmp" CIPI_LIB="$LIB" CIPI_LOG="/tmp"
# shellcheck source=/dev/null
if ( set -euo pipefail
     GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'
     CYAN=$'\033[0;36m'; DIM=$'\033[2m'; NC=$'\033[0m'; BOLD=$'\033[1m'
     error() { :; }; warn() { :; }; info() { :; }; success() { :; }; step() { :; }
     source "${LIB}/zt.sh"
     for fn in zt_command _zt_enable _zt_disable _zt_lock_ssh _zt_tunnel_healthy \
               _zt_ssh_ingress_present _zt_write_realip _zt_origin_cert; do
         declare -F "$fn" >/dev/null || exit 1
     done
   ); then
    pass "zt.sh defines expected functions"
else
    fail "zt.sh is missing functions after source"
fi
if ( set -euo pipefail
     export CIPI_CONFIG="/tmp" CIPI_LIB="$LIB" CIPI_LOG="/tmp"
     GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'
     CYAN=$'\033[0;36m'; DIM=$'\033[2m'; NC=$'\033[0m'; BOLD=$'\033[1m'
     error() { :; }; warn() { :; }; info() { :; }; success() { :; }; step() { :; }
     log_action() { :; }; log_event() { :; }
     vault_read() { echo '{}'; }; vault_write() { cat >/dev/null; }
     parse_args() { :; }
     _cipi_path_writable() { return 0; }
     source "${LIB}/monitor.sh"
     source "${LIB}/alerts.sh"
     for fn in monitor_command _mon_run_all _mon_apply_state _mon_check_disk \
               _mon_check_ssl _mon_check_services _mon_check_workers \
               _mon_check_http_5xx _mon_check_fs _mon_check_load \
               alerts_channel_command _alerts_deliver _alert_deliver_channel; do
         declare -F "$fn" >/dev/null || exit 1
     done
   ); then
    pass "monitor.sh + alerts.sh define expected functions"
else
    fail "monitor.sh/alerts.sh missing functions after source"
fi

echo "-- README / changelog intent"
grep -q 'cipi zt enable' "${ROOT}/README.md" \
    && pass "README documents cipi zt enable" || fail "README omits cipi zt"
grep -q 'cipi monitor' "${ROOT}/README.md" \
    && pass "README documents cipi monitor" || fail "README omits cipi monitor"
grep -q 'notifications channel add' "${ROOT}/README.md" \
    && pass "README documents alert channels" || fail "README omits channels"
grep -q 'HTTP-01' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG mentions HTTP-01 lock friction" || fail "CHANGELOG omits HTTP-01"
grep -q '/cipi/webhook' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG mentions webhook bypass" || fail "CHANGELOG omits webhook"
grep -q '5xx' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG mentions 5xx monitoring" || fail "CHANGELOG omits 5xx"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
