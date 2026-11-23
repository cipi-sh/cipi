#!/bin/bash
# 5.12.0: every notification channel and every trigger managed from the
# panel — `cipi notification triggers --json`, `triggers set --on= --off=`,
# `update <id>` (secrets kept when left out), a test that says when the
# channel refused it, the panel's sudoers entries. curl is a stub in front of
# PATH (a URL with "fail" in it is refused); the vault is a real one in a
# temporary /etc/cipi.
# Run from repo root: bash tests/verify-5.12.0.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0; FAIL=0
pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
TMP=$(mktemp -d) && [[ -n "$TMP" && -d "$TMP" ]] || exit 1
trap 'rm -rf "${TMP:?}"' EXIT
echo "=== Cipi 5.12.0 regression checks ==="

v=$(tr -d '[:space:]' < "${ROOT}/version.md")
[[ "$(printf '%s\n%s\n' 5.12.0 "$v" | sort -V | head -1)" == 5.12.0 ]] && pass "version.md is ${v} (>= 5.12.0)" || fail "version.md ${v}"
grep -q '^## \[5.12.0\]' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG 5.12.0" || fail "CHANGELOG"
for f in notifications.sh alerts.sh smtp.sh cipi-api-sudoers.sh completion.sh migrations/5.12.0.sh; do
    bash -n "${LIB}/${f}" && pass "${f} parses" || fail "${f}"
done
bash -n "${ROOT}/cipi" && pass "cipi parses" || fail "cipi"

for e in 'notification status --json' 'notification triggers --json' 'notification triggers set \*' \
         'notification add \*' 'notification update \*' 'notification remove \*' 'notification test \*' \
         'notification enable \*' 'notification disable \*' 'notification triggers enable-all' \
         'notification triggers disable-all' 'notification triggers reset'; do
    grep -q "/usr/local/bin/cipi ${e}" "${LIB}/cipi-api-sudoers.sh" && pass "panel sudoers: ${e//\\/}" || fail "sudoers lacks ${e//\\/}"
done

# ── a fake /etc/cipi with a real vault ──────────────────────
BIN="${TMP}/bin"; STATE="${TMP}/state"; CFG="${TMP}/etc/cipi"
mkdir -p "$BIN" "$STATE" "$CFG" "${TMP}/log"
head -c 32 /dev/urandom | base64 > "${CFG}/.vault_key"
cat > "${BIN}/curl" <<'EOF'
#!/bin/bash
url=""; for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
n=$(ls "$STATE"/req.* 2>/dev/null | wc -l); echo "$url" > "$STATE/req.$((n + 1))"
cat >/dev/null 2>&1 || true
[[ "$url" == *fail* ]] && exit 22
exit 0
EOF
chmod +x "${BIN}/curl"
N() {
    PATH="${BIN}:${PATH}" STATE="$STATE" CIPI_LIB="$LIB" CIPI_CONFIG="$CFG" CIPI_LOG="${TMP}/log" \
    bash -c 'set -euo pipefail
             RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""; BOLD=""
             source "$CIPI_LIB/common.sh"
             log_action() { :; }; log_event() { echo "$*" >> "$STATE/events"; }
             source "$CIPI_LIB/notifications.sh"; source "$CIPI_LIB/alerts.sh"; source "$CIPI_LIB/smtp.sh"
             '"$1" < /dev/null
}
alerts() { N 'vault_read alerts.json'; }

# ── triggers --json and set ─────────────────────────────────
out=$(N 'notifications_command triggers --json' 2>&1)
total=$(grep -c '^[a-z0-9_]*|' "${LIB}/notifications.sh")
jq -e --argjson t "$total" '.total == $t and .enabled == $t and (.triggers | length) == $t' <<< "$out" >/dev/null \
    && pass "triggers --json: all ${total} triggers, all on by default" || fail "triggers json: ${out:0:300}"
jq -e '.triggers[] | select(.id == "deploy_fail") | .category == "Deploy" and .label != "" and .enabled' <<< "$out" >/dev/null \
    && pass "triggers --json: id, category, label, enabled" || fail "deploy_fail entry"
[[ "$(N 'notifications_command triggers list --json' | jq -r .total)" == "$total" ]] && pass "triggers list --json is the same" || fail "list --json"
out=$(N 'notifications_command triggers set --off=deploy_success,ssh_login --on=deploy_fail' 2>&1); rc=$?
j=$(N 'notifications_command triggers --json')
[[ $rc -eq 0 ]] && jq -e '([.triggers[] | select(.id == "deploy_success" or .id == "ssh_login") | .enabled] == [false, false])
    and (.triggers[] | select(.id == "deploy_fail") | .enabled) and .enabled == (.total - 2)' <<< "$j" >/dev/null \
    && pass "triggers set: two off, one on, in one write" || fail "set: $out"
out=$(N 'notifications_command triggers set --off=deploy_fail,nope' 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"Unknown trigger: nope"* ]] && jq -e '.triggers[] | select(.id == "deploy_fail") | .enabled' <<< "$(N 'notifications_command triggers --json')" >/dev/null \
    && pass "triggers set: an unknown name changes nothing" || fail "unknown trigger: $out"
out=$(N 'notifications_command triggers set' 2>&1); rc=$?
[[ $rc -ne 0 ]] && pass "triggers set without --on/--off is refused" || fail "empty set"
N 'notifications_command triggers reset' >/dev/null 2>&1
[[ "$(N 'notifications_command triggers --json' | jq '.enabled == .total')" == true ]] && pass "triggers reset: all on again" || fail "reset"

# ── update keeps what is not given ──────────────────────────
N 'notifications_command add webhook siem --url=https://hooks.test/in --secret=s3cr3t' >/dev/null 2>&1
N 'notifications_command add telegram oncall --token=123456:ABC-def_GH --chat-id=-1001' >/dev/null 2>&1
N 'notifications_command add resend mail --api-key=re_Key_1 --from=alerts@example.com --to=ops@example.com' >/dev/null 2>&1
N 'notifications_command disable oncall' >/dev/null 2>&1
out=$(N 'notifications_command update oncall --chat-id=-2002' 2>&1); rc=$?
c=$(alerts)
[[ $rc -eq 0 ]] && jq -e '.channels[] | select(.id == "oncall") | .chat_id == "-2002" and .token == "123456:ABC-def_GH" and .enabled == false' <<< "$c" >/dev/null \
    && pass "update telegram: new chat id, the token kept, still disabled" || fail "update telegram: $out $c"
out=$(N 'notifications_command update mail --to="a@example.com, b@example.com"' 2>&1); rc=$?
c=$(alerts)
[[ $rc -eq 0 ]] && jq -e '.channels[] | select(.id == "mail") | .to == ["a@example.com","b@example.com"] and .api_key == "re_Key_1" and .from == "alerts@example.com"' <<< "$c" >/dev/null \
    && pass "update resend: recipients replaced, key and sender kept" || fail "update resend: $out"
out=$(N 'notifications_command update mail' 2>&1)
jq -e '.channels[] | select(.id == "mail") | .to == ["a@example.com","b@example.com"]' <<< "$(alerts)" >/dev/null \
    && pass "update with no flag keeps every value" || fail "noop update: $out"
out=$(N 'notifications_command update siem --url=https://hooks.test/v2' 2>&1)
jq -e '.channels[] | select(.id == "siem") | .url == "https://hooks.test/v2" and .secret == "s3cr3t"' <<< "$(alerts)" >/dev/null \
    && pass "update webhook: new URL, the signing secret kept" || fail "update webhook: $out"
N 'notifications_command update siem --clear-secret' >/dev/null 2>&1
jq -e '.channels[] | select(.id == "siem") | has("secret") | not' <<< "$(alerts)" >/dev/null \
    && pass "update webhook --clear-secret: unsigned from now on" || fail "clear secret: $(alerts)"
out=$(N 'notifications_command update siem --url=ftp://x' 2>&1); rc=$?
[[ $rc -ne 0 ]] && jq -e '.channels[] | select(.id == "siem") | .url == "https://hooks.test/v2"' <<< "$(alerts)" >/dev/null \
    && pass "update: an invalid value is refused, the channel unchanged" || fail "invalid update: $out"
out=$(N 'notifications_command update oncall --type=slack' 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"remove it and add"* ]] && pass "update cannot change the type" || fail "type change: $out"
out=$(N 'notifications_command update ghost --url=https://x.test' 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"not found"* ]] && pass "update of a missing channel: not found" || fail "missing: $out"
[[ "$(alerts | jq '[.channels[].id] == ["siem","oncall","mail"]')" == true ]] && pass "update keeps the order of the channels" || fail "order"
out=$(N 'notifications_command add webhook siem --url=https://x.test' 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"notification update siem"* ]] && pass "add of an existing id points to update" || fail "dup add: $out"

# SMTP: update is configure with the stored values
N 'jq -n "{host: \"smtp.test\", port: \"587\", user: \"u\", password: \"pw\", from: \"a@x.it\", to: \"b@x.it\", tls: true, enabled: true}" | vault_write smtp.json' >/dev/null 2>&1
out=$(N '_smtp_configure() { parse_args "$@"; echo "HOST=${ARG_host} TO=${ARG_to:-} PW=${ARG_password:-keep}"; }; notifications_command update smtp --to=c@x.it --no-test' 2>&1)
[[ "$out" == "HOST=smtp.test TO=c@x.it PW=keep" ]] && pass "update smtp: non-interactive, the stored host and password kept" || fail "update smtp: $out"
out=$(N '_smtp_configure() { parse_args "$@"; echo "HOST=${ARG_host}"; }; notifications_command update smtp --host=mail.test' 2>&1)
[[ "$out" == "HOST=mail.test" ]] && pass "update smtp --host: the given host wins" || fail "smtp host: $out"

# ── test says when it failed ────────────────────────────────
rm -f "$STATE"/req.*
out=$(N 'notifications_command test oncall' 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q 'api.telegram.org/bot123456:ABC-def_GH/sendMessage' "$STATE"/req.* \
    && pass "test reaches a disabled channel (try before turning on)" || fail "test disabled: $out"
N 'notifications_command update siem --url=https://hooks.test/fail' >/dev/null 2>&1
out=$(N 'notifications_command test siem' 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"failed"* ]] && pass "test: a refused request is an error (exit ${rc})" || fail "failed test passed: $out"
out=$(N 'cipi_notify "x" "y" deploy_fail; echo done' 2>&1)
[[ "$out" == *done* ]] && pass "a failing channel still never stops cipi_notify" || fail "notify: $out"

# ── status --json lists the types ───────────────────────────
out=$(N 'notifications_command status --json' 2>/dev/null)
jq -e '.types[0] == "smtp" and (.types | index("telegram")) and (.types | length) == 11' <<< "$out" >/dev/null \
    && pass "status --json: the channel types (smtp first)" || fail "types: $out"
! grep -qE 're_Key_1|ABC-def_GH|"pw"' <<< "$out" && pass "status --json shows no secret" || fail "secret in status"

grep -q 'notification update' "${LIB}/completion.sh" || grep -q 'update' <(sed -n '/notification|notifications|notify|triggers)/,/;;/p' "${LIB}/completion.sh") \
    && pass "completion knows update" || fail "completion update"
grep -q 'cipi notification update <id>' "${ROOT}/cipi" && pass "help documents update" || fail "help update"

echo ""; echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
