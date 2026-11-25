#!/bin/bash
# 5.15.0:
#  - the root password of MySQL/MariaDB never on a client's command line: an
#    option file read from a pipe (db_mysql_as_root). On a server switched to
#    MySQL its client warned on stderr at every call — "mysql: [Warning]
#    Using a password on the command line interface can be insecure." — and
#    `cipi db list`, which read stderr with the rows, listed that line as a
#    database (in the panel too);
#  - per-channel notifications: `cipi notification events <channel> …` —
#    categories, triggers, urgent, all — honoured by every sender, the PAM,
#    cron and deploy-webhook helpers included (they reached SMTP alone);
#  - the visitor's address behind Cloudflare from the panel: `real_ip` in
#    `cipi firewall status --json`, `cipi nginx real-ip` in its sudoers.
# mysql, curl and systemctl are stubs; the vault is real.
# Run from repo root: bash tests/verify-5.15.0.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0; FAIL=0
pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
TMP=$(mktemp -d) && [[ -n "$TMP" && -d "$TMP" ]] || exit 1
trap 'rm -rf "${TMP:?}"' EXIT
echo "=== Cipi 5.15.0 regression checks ==="

v=$(tr -d "[:space:]" < "${ROOT}/version.md"); [[ "$(printf "%s\n%s\n" 5.15.0 "$v" | sort -V | head -1)" == 5.15.0 ]] && pass "version.md >= 5.15.0" || fail "version.md"
grep -q '^## \[5.15.0\]' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG 5.15.0" || fail "CHANGELOG"
for f in "${ROOT}/cipi" "${LIB}/common.sh" "${LIB}/db.sh" "${LIB}/reset.sh" "${LIB}/notifications.sh" "${LIB}/alerts.sh" \
         "${LIB}/smtp.sh" "${LIB}/cipi-cron-notify.sh" "${LIB}/cipi-app-notify.sh" "${LIB}/cipi-auth-notify.sh" \
         "${LIB}/nginx.sh" "${LIB}/firewall.sh" "${LIB}/cipi-api-sudoers.sh" "${LIB}/completion.sh"; do
    bash -n "$f" && pass "$(basename "$f") parses" || fail "$(basename "$f") parse"
done
command -v jq >/dev/null 2>&1 || { echo "  (jq not installed)"; exit 1; }

# ── no root password on a command line ───────────────────────
left=$(grep -rnE -- '-p"\$|-p\$\{|--password=\$' "${LIB}"/*.sh "${ROOT}/setup.sh" | grep -vE 'PGPASSWORD|_help|usage|Usage' || true)
[[ -z "$left" ]] && pass "no mysql/mysqldump call passes the root password with -p" || fail "still on a command line: ${left}"

BIN="${TMP}/bin"; STATE="${TMP}/state"; CFG="${TMP}/etc/cipi"
mkdir -p "$BIN" "$STATE" "$CFG" "${TMP}/log"
head -c 32 /dev/urandom | base64 > "${CFG}/.vault_key"

# The MySQL 8 client as far as this matters: -p<pw> on the command line → the
# warning on stderr; the password read from --defaults-extra-file (first).
cat > "${BIN}/mysql" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STATE/mysql.argv"
pw=""
for a in "$@"; do
    case "$a" in
        --defaults-extra-file=*) f="${a#--defaults-extra-file=}"; cat "$f" > "$STATE/mysql.cnf"
                                 pw=$(sed -n 's/^password="\(.*\)"$/\1/p' "$STATE/mysql.cnf" | sed 's/\\\\/\\/g') ;;
        -p*) pw="${a#-p}"; echo "mysql: [Warning] Using a password on the command line interface can be insecure." >&2 ;;
    esac
done
[[ "$pw" == "$(cat "$STATE/rootpw")" ]] || { echo "ERROR 1045 (28000): Access denied for user 'root'@'localhost' (using password: YES)" >&2; exit 1; }
[[ -f "$STATE/mysql.fail" ]] && { echo "ERROR 2002 (HY000): Can't connect to local MySQL server through socket" >&2; exit 1; }
printf 'mozart\t12.50\nshop\t0.00\n'
EOF
cp "${BIN}/mysql" "${BIN}/mysqldump"
cat > "${BIN}/systemctl" <<'EOF'
#!/bin/bash
case "$*" in
    *is-active*crowdsec*) [[ -f "$STATE/crowdsec.on" ]] ;;
    *is-active*fail2ban*) [[ -f "$STATE/fail2ban.on" ]] ;;
    *) exit 0 ;;
esac
EOF
cat > "${BIN}/curl" <<'EOF'
#!/bin/bash
url=""; for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
echo "$url" >> "$STATE/requests"
cat >/dev/null 2>&1 || true
exit 0
EOF
cat > "${BIN}/msmtp" <<'EOF'
#!/bin/bash
cat > /dev/null; echo "smtp $*" >> "$STATE/requests"
EOF
chmod +x "${BIN}"/*
N() {
    PATH="${BIN}:${PATH}" STATE="$STATE" CIPI_LIB="$LIB" CIPI_CONFIG="$CFG" CIPI_LOG="${TMP}/log" \
    bash -c 'set -euo pipefail
             RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""; BOLD=""
             source "$CIPI_LIB/common.sh"
             log_action() { :; }; log_event() { :; }
             source "$CIPI_LIB/notifications.sh"; source "$CIPI_LIB/alerts.sh"; source "$CIPI_LIB/smtp.sh"
             '"$1" < /dev/null
}

printf '%s' 'Root9pw\x' > "${STATE}/rootpw"
N 'jq -n --arg p "$(cat "$STATE/rootpw")" "{db_root_password: \$p, db_engines: {mariadb: {installed: true, server: \"mysql\"}}}" | vault_write server.json' >/dev/null 2>&1
DBL='source "$CIPI_LIB/db.sh"; db_engine_is_installed() { [[ "$1" == mariadb ]]; }; db_ensure_engine_state() { :; }; '

out=$(N "${DBL}"'_db_list --engine=mariadb --json' 2>"${TMP}/err"); rc=$?
[[ $rc -eq 0 ]] && jq -e '[.databases[].name] == ["mozart", "shop"]' <<< "$out" >/dev/null \
    && pass "db list --json on MySQL: the databases, and nothing the client said on stderr" || fail "db list: rc=${rc} ${out:0:300} $(cat "${TMP}/err")"
! grep -q -- ' -p' "${STATE}/mysql.argv" && grep -q -- '--defaults-extra-file=' "${STATE}/mysql.argv" \
    && pass "the client gets the password from an option file, not from -p" || fail "argv: $(cat "${STATE}/mysql.argv")"
grep -qx 'password="Root9pw\\\\x"' "${STATE}/mysql.cnf" && pass "the option file holds the password, a backslash escaped" || fail "cnf: $(cat "${STATE}/mysql.cnf")"
head -1 "${STATE}/mysql.argv" | grep -q -- '^--defaults-extra-file=.* -u root ' && pass "--defaults-extra-file comes first, -u root after it" || fail "order: $(head -1 "${STATE}/mysql.argv")"
grep -qE '(^| )-u root( |$)' "${STATE}/mysql.argv" && pass "-u root stays on the command line" || fail "-u root"
out=$(N "${DBL}"'_db_list --engine=mariadb' 2>/dev/null)
grep -q 'mozart' <<< "$out" && ! grep -qi 'warning' <<< "$out" && pass "db list (table): no warning row" || fail "table: ${out}"

touch "${STATE}/mysql.fail"
out=$(N "${DBL}"'_db_list --engine=mariadb --json' 2>&1); rc=$?
[[ $rc -ne 0 ]] && grep -q "query failed: ERROR 2002" <<< "$out" && pass "a failed query still says why (from stderr)" || fail "failure: rc=${rc} ${out}"
rm -f "${STATE}/mysql.fail"

out=$(N "${DBL}"'db_list_databases mariadb' 2>&1)
[[ "$out" == $'mozart\t12.50\nshop\t0.00' || "$out" == *mozart* ]] && pass "db_list_databases through the option file" || fail "list_databases: ${out}"
out=$(N "${DBL}"'db_mysql_as_root "$(cat "$STATE/rootpw")" mysql -N -e "SELECT 1"' 2>&1)
[[ "$out" == *mozart* && "$out" != *Warning* ]] && pass "db_mysql_as_root: no warning, the query runs" || fail "as_root: ${out}"
grep -q 'db_mysql_as_root "$old_pass"' "${LIB}/reset.sh" && pass "reset db-password: the old password through the option file" || fail "reset.sh"
grep -q 'db_mysql_as_root "$dbr" mysqldump' "${LIB}/db.sh" && pass "mysqldump through the option file" || fail "mysqldump"
grep -q '2>"$qerr"' "${LIB}/db.sh" && ! grep -q 'ORDER BY datname;" 2>&1' "${LIB}/db.sh" \
    && pass "db list keeps stderr apart for PostgreSQL too" || fail "pgsql list still merges stderr"

# ── notifications: what each channel takes ───────────────────
N 'jq -n "{host: \"smtp.test\", port: \"587\", user: \"u\", password: \"pw\", from: \"a@x.it\", to: \"b@x.it\", tls: true, enabled: true}" | vault_write smtp.json' >/dev/null 2>&1
N 'notifications_command add slack ops --url=https://hooks.slack.test/ops' >/dev/null 2>&1
N 'notifications_command add slack sec --url=https://hooks.slack.test/sec --events=security' >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 && "$(N 'vault_read alerts.json' | jq -c '.channels[] | select(.id == "sec") | .events')" == '["security"]' ]] \
    && pass "add … --events=security" || fail "add --events: $(N 'vault_read alerts.json' 2>&1)"
N 'notifications_command add ntfy pager --url=https://ntfy.test/pager' >/dev/null 2>&1
out=$(N 'notifications_command events pager urgent' 2>&1); rc=$?
[[ $rc -eq 0 && "$(N 'vault_read alerts.json' | jq -c '.channels[] | select(.id == "pager") | .events')" == '["urgent"]' ]] \
    && pass "events <id> urgent" || fail "events urgent: ${out}"
out=$(N 'notifications_command events smtp deploy,backup_fail' 2>&1); rc=$?
[[ $rc -eq 0 && "$(N 'vault_read smtp.json' | jq -c '.events')" == '["deploy","backup_fail"]' ]] \
    && pass "events smtp: a category and a trigger" || fail "events smtp: ${out}"
before=$(N 'vault_read alerts.json')
out=$(N 'notifications_command events ops deploy,nope' 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"'nope'"* && "$(N 'vault_read alerts.json')" == "$before" ]] \
    && pass "an unknown selector is refused by name, nothing written" || fail "refusal: rc=${rc} ${out}"
out=$(N 'notifications_command update sec --url=https://hooks.slack.test/sec2 --events=nope' 2>&1); rc=$?
[[ $rc -ne 0 && "$(N 'vault_read alerts.json' | jq -r '.channels[] | select(.id == "sec") | .url')" == "https://hooks.slack.test/sec" ]] \
    && pass "update with a bad --events changes nothing, the URL included" || fail "update bad events: ${out}"
N 'notifications_command update sec --url=https://hooks.slack.test/sec2' >/dev/null 2>&1
[[ "$(N 'vault_read alerts.json' | jq -c '.channels[] | select(.id == "sec") | [.url, .events]')" == '["https://hooks.slack.test/sec2",["security"]]' ]] \
    && pass "update without --events keeps what the channel takes" || fail "update dropped events: $(N 'vault_read alerts.json')"
N 'notifications_command update smtp --to=c@x.it --no-test' >/dev/null 2>&1
[[ "$(N 'vault_read smtp.json' | jq -c '[.to, .events]')" == '["c@x.it",["deploy","backup_fail"]]' ]] \
    && pass "reconfiguring SMTP keeps what it takes" || fail "smtp events lost: $(N 'vault_read smtp.json' | jq -c 'del(.password)')"
N 'notifications_command update ops --events=all' >/dev/null 2>&1
[[ "$(N 'vault_read alerts.json' | jq -c '.channels[] | select(.id == "ops") | has("events")')" == false ]] \
    && pass "--events=all: back to everything (no list kept)" || fail "all"

j=$(N 'notifications_command status --json')
jq -e '(.channels[] | select(.id == "smtp") | .events) == ["deploy","backup_fail"]
       and (.channels[] | select(.id == "ops") | .events) == null
       and (.categories | map(.id) | index("security") and index("basic-auth") and index("cipi-yml"))
       and (.selectors[:2] == ["all", "urgent"])' <<< "$j" >/dev/null \
    && pass "status --json: events per channel, the categories and selectors" || fail "status json: ${j:0:400}"
jq -e '.triggers[] | select(.id == "basicauth_enable") | .category_id == "basic-auth"' <<< "$(N 'notifications_command triggers --json')" >/dev/null \
    && pass "triggers --json: category_id" || fail "category_id"
j=$(N 'notifications_command events --json')
jq -e '[.channels[].id] == ["smtp", "ops", "sec", "pager"]' <<< "$j" >/dev/null && pass "events --json: every channel" || fail "events json: ${j}"

# Who gets what.
route() {   # <trigger> → the channels reached
    rm -f "${STATE}/requests"
    N "cipi_notify 'subject' 'body' '$1'" >/dev/null 2>&1
    local r=""
    grep -q '^smtp' "${STATE}/requests" 2>/dev/null && r+="smtp "
    grep -q 'slack.test/ops' "${STATE}/requests" 2>/dev/null && r+="ops "
    grep -q 'slack.test/sec' "${STATE}/requests" 2>/dev/null && r+="sec "
    grep -q 'ntfy.test/pager' "${STATE}/requests" 2>/dev/null && r+="pager "
    echo "${r% }"
}
[[ "$(route ssh_login)" == "ops sec pager" ]] && pass "ssh_login: everything-channel, security, urgent — not SMTP (deploy, backup_fail)" || fail "ssh_login → $(route ssh_login)"
[[ "$(route deploy_success)" == "smtp ops" ]] && pass "deploy_success: SMTP (deploy) and the everything-channel" || fail "deploy_success → $(route deploy_success)"
[[ "$(route backup_fail)" == "smtp ops pager" ]] && pass "backup_fail: SMTP (the trigger), everything, urgent" || fail "backup_fail → $(route backup_fail)"
[[ "$(route app_create)" == "ops" ]] && pass "app_create: the everything-channel alone" || fail "app_create → $(route app_create)"
N 'notifications_command triggers disable app_create' >/dev/null 2>&1
[[ "$(route app_create)" == "" ]] && pass "a trigger that is off reaches nobody" || fail "off trigger → $(route app_create)"
rm -f "${STATE}/requests"; N 'cipi_notify "subject" "body" ""' >/dev/null 2>&1
[[ $(grep -c . "${STATE}/requests") -eq 4 ]] && pass "no trigger (a test): every channel" || fail "no trigger: $(cat "${STATE}/requests")"
rm -f "${STATE}/requests"; N 'notifications_command test sec' >/dev/null 2>&1
grep -q 'slack.test/sec' "${STATE}/requests" && pass "test <id> reaches a filtered channel" || fail "test"

# The helpers that do not go through cipi_notify.
rm -f "${STATE}/requests"
PATH="${BIN}:${PATH}" STATE="$STATE" CIPI_LIB="$LIB" CIPI_CONFIG="$CFG" CIPI_LOG="${TMP}/log" \
    bash "${LIB}/cipi-cron-notify.sh" nightly false >/dev/null 2>&1
grep -q 'ntfy.test/pager' "${STATE}/requests" 2>/dev/null && grep -q 'slack.test/ops' "${STATE}/requests" && ! grep -q '^smtp' "${STATE}/requests" \
    && pass "cipi-cron-notify: cron_fail to the channels that take it (urgent, everything), not SMTP" || fail "cron-notify: $(cat "${STATE}/requests" 2>/dev/null)"
grep -q '_notify_fanout "$SUBJECT" "$BODY" "$NOTIFY_TRIGGER"' "${LIB}/cipi-app-notify.sh" && pass "cipi-app-notify sends through every channel" || fail "app-notify"
grep -q '_notify_fanout "$SUBJECT" "$BODY" "$NOTIFY_TRIGGER" >/dev/null 2>&1 &' "${LIB}/cipi-auth-notify.sh" \
    && grep -q 'alerts.json" ]] || exit 0' "${LIB}/cipi-auth-notify.sh" \
    && pass "cipi-auth-notify: every channel, in the background, without SMTP too" || fail "auth-notify"

# ── the visitor's address behind Cloudflare, from the panel ──
for e in 'nginx real-ip status --json' 'nginx real-ip cloudflare' 'nginx real-ip refresh' 'nginx real-ip off --yes'; do
    grep -q "/usr/local/bin/cipi ${e}, " "${LIB}/cipi-api-sudoers.sh" && pass "panel sudoers: ${e}" || fail "sudoers lacks ${e}"
done
! grep -qE 'nginx real-ip \*|nginx real-ip [a-z]+ \*|nginx real-ip off(, |$)' "${LIB}/cipi-api-sudoers.sh" \
    && pass "panel sudoers: off only with --yes, no wildcard" || fail "sudoers too wide"
RIP="${TMP}/realip"; mkdir -p "${RIP}/conf.d" "${RIP}/ips" "${RIP}/cron"
RN() {
    PATH="${BIN}:${PATH}" STATE="$STATE" CIPI_LIB="$LIB" CIPI_CONFIG="$CFG" CIPI_LOG="${TMP}/log" \
    ZT_REALIP="${RIP}/conf.d/cipi-cloudflare-realip.conf" ZT_IPS_DIR="${RIP}/ips" ZT_CRON="${RIP}/cron/zt" \
    NGINX_REALIP_CRON="${RIP}/cron/realip" \
    bash -c 'set -uo pipefail
             RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""; BOLD=""
             source "$CIPI_LIB/common.sh"; source "$CIPI_LIB/zt.sh"; source "$CIPI_LIB/nginx.sh"
             _zt_enabled() { [[ -f "$STATE/zt.on" ]]; }
             '"$1" < /dev/null
}
j=$(RN '_nginx_realip_json')
jq -e '.enabled == false and .can_disable == false and .bans_active == false and .kept_by == null' <<< "$j" >/dev/null \
    && pass "real_ip off: enabled false, nothing to turn off" || fail "off json: ${j}"
printf 'real_ip_header CF-Connecting-IP;\nset_real_ip_from 173.245.48.0/20;\nset_real_ip_from 2400:cb00::/32;\n' > "${RIP}/conf.d/cipi-cloudflare-realip.conf"
touch "${RIP}/cron/realip" "${STATE}/fail2ban.on"
j=$(RN '_nginx_realip_json')
jq -e '.enabled and .provider == "cloudflare" and .kept_by == "real-ip" and .ranges == 2 and .can_disable and .bans_active and .nightly_refresh' <<< "$j" >/dev/null \
    && pass "real_ip on by the command: ranges, can_disable, bans_active (fail2ban runs)" || fail "on json: ${j}"
touch "${STATE}/zt.on"; rm -f "${RIP}/cron/realip"
j=$(RN '_nginx_realip_json')
jq -e '.enabled and .kept_by == "zero-trust" and (.can_disable | not)' <<< "$j" >/dev/null \
    && pass "kept by Zero Trust: not for the panel to turn off" || fail "zt json: ${j}"
[[ "$(RN '_nginx_realip_status --json' | jq -r .kept_by)" == zero-trust ]] && pass "nginx real-ip status --json is the same reader" || fail "status --json"
grep -q 'real_ip: \$realip' "${LIB}/firewall.sh" && grep -q '_nginx_realip_json' "${LIB}/firewall.sh" \
    && pass "firewall status --json carries real_ip" || fail "firewall status lacks real_ip"

echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
