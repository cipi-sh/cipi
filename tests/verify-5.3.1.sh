#!/bin/bash
# Local regression checks for 5.3.1 — `cipi compliance` (evidence report),
# `cipi redirect` and `cipi proxy`.
# Run from repo root: bash tests/verify-5.3.1.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
CMP="${LIB}/compliance.sh"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# Code lines only (comments stripped). Held in a variable: `producer | grep -q`
# under pipefail reports SIGPIPE as failure when grep matches early.
CODE=$(grep -vE '^[[:space:]]*#' "$CMP" 2>/dev/null)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "=== Cipi 5.3.1 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.3.1" ]] \
    && pass "version.md is 5.3.1" || fail "version.md is not 5.3.1"
grep -q '^## \[5.3.1\]' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.3.1 entry" || fail "CHANGELOG has no 5.3.1 entry"
grep -q '^## \[Unreleased\]' "${ROOT}/CHANGELOG.md" \
    && fail "CHANGELOG still has an Unreleased section" || pass "no Unreleased section left"
[[ ! -f "${LIB}/migrations/5.3.1.sh" ]] \
    && pass "no 5.3.1 migration (nothing to install)" || fail "unexpected 5.3.1 migration"
[[ -f "$CMP" ]] && pass "lib/compliance.sh present" || fail "missing lib/compliance.sh"

echo "-- syntax"
for f in "${ROOT}/cipi" "$CMP" "${LIB}/completion.sh"; do
    bash -n "$f" 2>/dev/null && pass "syntax $(basename "$f")" || { fail "syntax $(basename "$f")"; bash -n "$f"; }
done

echo "-- dispatch / help / completion"
grep -q 'source "${CIPI_LIB}/compliance.sh"' "${ROOT}/cipi" && pass "cipi sources compliance.sh" || fail "cipi does not source compliance.sh"
grep -q 'compliance_command' "${ROOT}/cipi" && pass "cipi dispatches compliance" || fail "no compliance dispatch"
grep -q '_help_cmd "cipi compliance' "${ROOT}/cipi" && pass "top-level help mentions compliance" || fail "help omits compliance"
grep -q 'show_help_topic compliance' "${ROOT}/cipi" && pass "help all includes compliance" || fail "help all omits compliance"
grep -q ' compliance ' <<< "$(sed -n '/_help_topics_list()/,/^EOF/p' "${ROOT}/cipi")" \
    && pass "compliance is in the help topics list" || fail "compliance missing from topics list"
cmds=$(sed -n 's/.*local commands="\([^"]*\)".*/\1/p' "${LIB}/completion.sh" | head -1)
topics=$(sed -n 's/.*local topics="\([^"]*\)".*/\1/p' "${LIB}/completion.sh" | head -1)
[[ " $cmds " == *" compliance "* ]] && pass "completion verb list has compliance" || fail "completion verbs miss compliance"
[[ " $topics " == *" compliance "* ]] && pass "completion topics have compliance" || fail "completion topics miss compliance"

echo "-- catalog"
# shellcheck source=/dev/null
catalog=$(bash -c "source '$CMP' 2>/dev/null; _cmp_catalog" 2>/dev/null)
n=$(grep -c . <<<"$catalog")
[[ "$n" -ge 15 ]] && pass "catalog has ${n} controls" || fail "catalog has only ${n} controls"
bad=$(awk -F'|' 'NF != 4 || $3 !~ /^A\.[58]\./ || $4 !~ /^(CC|A1)/' <<<"$catalog")
[[ -z "$bad" ]] && pass "every control has 4 fields and ISO + SOC 2 mappings" || fail "malformed catalog rows: ${bad}"
while IFS='|' read -r id _; do
    [[ -z "$id" ]] && continue
    grep -q "^_cmp_check_${id}() {" "$CMP" && pass "check function for ${id}" || fail "no _cmp_check_${id}"
done <<<"$catalog"
dups=$(cut -d'|' -f1 <<<"$catalog" | sort | uniq -d)
[[ -z "$dups" ]] && pass "control ids are unique" || fail "duplicate control ids: ${dups}"

echo "-- read-only: no check may change the server"
for pat in 'vault_write' 'apt-get (update|install|upgrade)' 'apt (update|install|upgrade)' \
           'ufw (allow|deny|enable|disable|delete)' 'systemctl (start|stop|restart|enable|disable|reload)' \
           'sysctl -w' 'chmod [0-7]+ /etc' 'sed -i'; do
    if grep -qE "$pat" <<<"$CODE"; then
        fail "compliance.sh runs a mutating command: ${pat}"
    else
        pass "no '${pat}'"
    fi
done

echo "-- no secrets in the bundle"
grep -qiE 'SELECT \*' <<<"$CODE" \
    && fail "SELECT * would export password / token hashes" || pass "no SELECT * on panel databases"
grep -E '_cmp_sqlite_columns' <<<"$CODE" | grep -qE '[[:space:]](token|password|two_factor_secret|two_factor_recovery_codes|remember_token)([[:space:]]|\)|$)' \
    && fail "a secret column is selected" || pass "no secret column selected"
grep -qE 'cat[^|]*(\.vault_key|\.backup_key|alerts\.json|smtp\.json|zt\.token)' <<<"$CODE" \
    && fail "a secret file is copied into evidence" || pass "no secret file copied into evidence"
grep -qE -- '-readonly' <<<"$CODE" \
    && pass "sqlite3 opened read-only" || fail "sqlite3 not opened with -readonly"

echo "-- deploy log parser"
cat > "${TMP}/deploy.log" <<'EOF'
[2026-01-01 10:00:00] ===== deploy start  app=shop trigger=cli branch=main from-release=3 =====
[2026-01-01 10:00:05] ===== deploy OK  app=shop release=4 duration=5s exit=0 =====

[2026-09-10 10:00:00] ===== deploy start  app=shop trigger=webhook branch=main from-release=4 =====
[2026-09-10 10:00:01] Deployer output
[2026-09-10 10:00:09] ===== deploy FAILED  app=shop release=4 duration=9s exit=1 =====

[2026-09-11 10:00:00] ===== deploy start  app=shop trigger=rollback branch=main from-release=5 =====
[2026-09-11 10:00:03] ===== deploy ROLLBACK OK  app=shop release=4 duration=3s exit=0 =====
EOF
parsed=$(bash -c "source '$CMP' 2>/dev/null; _cmp_parse_deploy_log '${TMP}/deploy.log' '2026-06-01 00:00:00'")
[[ "$(grep -c . <<<"$parsed")" == "2" ]] && pass "period filter drops deploys before --days" || fail "expected 2 deploys, got: ${parsed}"
[[ "$(sed -n 1p <<<"$parsed")" == $'2026-09-10 10:00:00\tshop\twebhook\tmain\t4\tFAILED\t4\t1' ]] \
    && pass "failed webhook deploy parsed" || fail "failed deploy row wrong: $(sed -n 1p <<<"$parsed")"
[[ "$(sed -n 2p <<<"$parsed" | cut -f3,6)" == $'rollback\tOK' ]] \
    && pass "ROLLBACK OK banner parsed as a rollback" || fail "rollback row wrong: $(sed -n 2p <<<"$parsed")"

echo "-- markdown rendering"
cat > "${TMP}/report.json" <<'EOF'
{"meta":{"hostname":"web1","fqdn":"web1.example.com","machine_id":"abc","os":"Ubuntu 24.04","kernel":"6.8","cipi_version":"5.3.0","generated_at":"2026-09-17T10:00:00Z","generated_by":"cipi","period_days":90},
 "summary":{"pass":1,"warn":0,"fail":1,"info":0,"na":0},
 "controls":[
  {"id":"ssh","title":"SSH hardening","iso27001":["A.8.5"],"soc2":["CC6.1"],"status":"pass","summary":"a | b","detail":"x","evidence":["evidence/ssh/sshd-effective.txt"]},
  {"id":"time","title":"Clock synchronisation","iso27001":["A.8.17"],"soc2":["CC7.2"],"status":"fail","summary":"NTP off","detail":"","evidence":[]}]}
EOF
md=$(bash -c "source '$CMP' 2>/dev/null; _cmp_render_md '${TMP}/report.json'")
grep -q '^# Compliance evidence report — web1$' <<<"$md" && pass "report title" || fail "report title missing"
grep -qF '| SSH hardening | A.8.5 | CC6.1 | ✅ PASS | a \| b |' <<<"$md" && pass "summary row escapes |" || fail "summary row wrong"
grep -qF '### Clock synchronisation — ❌ FAIL' <<<"$md" && pass "control section with status" || fail "control section missing"
grep -qF -- '- `evidence/ssh/sshd-effective.txt`' <<<"$md" && pass "evidence files listed" || fail "evidence list missing"
grep -qi 'does not replace' <<<"$md" && pass "disclaimer present" || fail "disclaimer missing"

RT="${LIB}/routes.sh"
[[ -f "$RT" ]] && pass "lib/routes.sh present" || fail "missing lib/routes.sh"

echo "-- syntax (redirect / proxy)"
for f in "${ROOT}/cipi" "$RT" "${LIB}/app.sh" "${LIB}/completion.sh" "${LIB}/common.sh" "${LIB}/notifications.sh"; do
    bash -n "$f" 2>/dev/null && pass "syntax $(basename "$f")" || { fail "syntax $(basename "$f")"; bash -n "$f"; }
done

echo "-- dispatch / help / completion (redirect / proxy)"
grep -q 'source "${CIPI_LIB}/routes.sh"; redirect_command' "${ROOT}/cipi" && pass "cipi dispatches redirect" || fail "no redirect dispatch"
grep -q 'source "${CIPI_LIB}/routes.sh";      proxy_command' "${ROOT}/cipi" && pass "cipi dispatches proxy" || fail "no proxy dispatch"
grep -q 'show_help_topic redirect' "${ROOT}/cipi" && pass "help all includes redirect" || fail "help all omits redirect"
grep -q 'show_help_topic proxy' "${ROOT}/cipi" && pass "help all includes proxy" || fail "help all omits proxy"
topics=$(sed -n '/_help_topics_list()/,/^EOF/p' "${ROOT}/cipi")
grep -q ' redirect ' <<< "$topics" && grep -q ' proxy ' <<< "$topics" \
    && pass "redirect and proxy in the help topics list" || fail "topics list omits redirect/proxy"
cmds=$(sed -n 's/.*local commands="\([^"]*\)".*/\1/p' "${LIB}/completion.sh" | head -1)
grep -qw redirect <<< "$cmds" && grep -qw proxy <<< "$cmds" \
    && pass "completion verbs include redirect and proxy" || fail "completion omits redirect/proxy"
grep -q '^redirect_change|' "${LIB}/notifications.sh" && grep -q '^proxy_change|' "${LIB}/notifications.sh" \
    && pass "notification triggers redirect_change, proxy_change" || fail "missing notification triggers"
grep -q 'redirect, redirects, proxies' "${LIB}/common.sh" \
    && pass "apps-public projection carries routes" || fail "apps-public omits routes"
if grep -qE 'cipi (redirect|proxy)' "${LIB}/cipi-api-sudoers.sh"; then
    fail "panel sudoers exposes redirect/proxy (CLI only)"
else
    pass "panel sudoers unchanged"
fi

echo "-- vhost wiring"
[[ "$(grep -c '\${reverb_block}\${route_blocks}' "${LIB}/app.sh")" == "3" ]] \
    && pass "route blocks in custom, Octane and FPM vhosts" || fail "route blocks not in all three vhost types"
grep -q '_nginx_redirect_location_blocks "\$app"' "${LIB}/app.sh" && pass "vhost renders redirects" || fail "vhost ignores redirects"
grep -q '_nginx_proxy_location_blocks "\$app" "\$auth_block"' "${LIB}/app.sh" && pass "vhost renders proxies with auth" || fail "vhost ignores proxies"

# ── functional: render from a fixture apps.json ──────────────
cat > "${TMP}/apps.json" <<'EOF'
{"shop":{"domain":"shop.test","aliases":["www.shop.test"],"php":"8.4","reverb":"true","reverb_port":"8081",
  "redirects":[{"from":"/old","to":"/new","code":301,"keep_path":true},
               {"from":"/blog/","to":"https://blog.test/","code":308,"keep_path":true},
               {"from":"/promo/","to":"/sale","code":302,"keep_path":false},
               {"from":"/q","to":"/r?x=1","code":301,"keep_path":true}],
  "proxies":[{"prefix":"/api/","upstream":"http://10.0.0.5:8080","strip_prefix":true,"timeout":60},
             {"prefix":"/v2/","upstream":"https://api.ext.test/base/","strip_prefix":true,"preserve_host":true,"timeout":120,"buffering":false},
             {"prefix":"/keep/","upstream":"http://127.0.0.1:3000"}],
  "redirect":{"enabled":true,"to":"https://new.test","code":301,"keep_path":true}},
 "other":{"domain":"o.test","octane_port":"8001"}}
EOF
cat > "${TMP}/h.sh" <<EOF
export CIPI_LIB="${LIB}" CIPI_CONFIG="${TMP}/cfg" CIPI_LOG="${TMP}/log"
mkdir -p "${TMP}/cfg" "${TMP}/log" "${TMP}/sites"
RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
source "${LIB}/common.sh" 2>/dev/null
vault_read() { cat "${TMP}/apps.json"; }
vault_write() { local t; t=\$(cat); printf '%s\n' "\$t" > "${TMP}/apps.json"; }
ensure_apps_json_api_access() { :; }
_ensure_nginx_octane_map() { :; }
cipi_notify() { :; }; log_action() { :; }; curl() { return 0; }
source "${RT}"
eval "\$(declare -f _create_nginx_vhost | sed 's|/etc/nginx/sites-available/|${TMP}/sites/|g')"
EOF
H="source '${TMP}/h.sh';"

echo "-- redirect rendering"
red=$(bash -c "$H _nginx_redirect_location_blocks shop" 2>&1)
grep -qF 'location = /old { return 301 "/new$is_args$args"; }' <<< "$red" && pass "exact redirect keeps query" || fail "exact redirect: ${red}"
grep -qF 'if ($request_uri ~ "^/blog/(.*)$") { return 308 "https://blog.test/$1"; }' <<< "$red" \
    && pass "prefix redirect appends rest of URI" || fail "prefix redirect wrong"
grep -qF 'location = /blog { return 308 "https://blog.test/"; }' <<< "$red" && pass "prefix without slash redirected" || fail "no = /blog"
grep -qF 'location ^~ /promo/ { return 302 "/sale"; }' <<< "$red" && pass "--no-path prefix" || fail "no-path prefix wrong"
grep -qF 'location = /q { return 301 "/r?x=1"; }' <<< "$red" && pass "target query not doubled" || fail "target query wrong"

echo "-- proxy rendering"
prx=$(bash -c "$H _nginx_proxy_location_blocks shop '        auth_basic \"R\";
'" 2>&1)
grep -qF 'proxy_pass http://10.0.0.5:8080/;' <<< "$prx" && pass "--strip-prefix adds URI part" || fail "strip proxy_pass wrong"
grep -qF 'proxy_pass http://127.0.0.1:3000;' <<< "$prx" && pass "keep-prefix has no URI part" || fail "keep proxy_pass wrong"
grep -qF 'proxy_pass https://api.ext.test/base/;' <<< "$prx" && pass "upstream path kept" || fail "upstream path wrong"
grep -qF 'proxy_set_header X-Forwarded-Prefix /api;' <<< "$prx" && pass "X-Forwarded-Prefix on strip" || fail "no X-Forwarded-Prefix"
[[ "$(grep -c 'X-Forwarded-Prefix' <<< "$prx")" == "2" ]] && pass "no X-Forwarded-Prefix without strip" || fail "X-Forwarded-Prefix count wrong"
grep -qF 'proxy_set_header Host $host;' <<< "$prx" && pass "--preserve-host" || fail "preserve-host wrong"
[[ "$(grep -c 'proxy_ssl_server_name on' <<< "$prx")" == "1" ]] && pass "SNI only for https upstream" || fail "SNI wrong"
[[ "$(grep -c 'proxy_buffering off' <<< "$prx")" == "1" ]] && pass "--no-buffering only where set" || fail "buffering wrong"
[[ "$(grep -c 'auth_basic "R"' <<< "$prx")" == "3" ]] && pass "basic auth in every proxy location" || fail "auth not in proxies"
grep -qF 'proxy_set_header Connection $connection_upgrade;' <<< "$prx" && pass "WebSocket upgrade" || fail "no upgrade header"

echo "-- app redirect vhost"
bash -c "$H _create_nginx_vhost shop shop.test 8.4" >/dev/null 2>&1
v="${TMP}/sites/shop"
grep -qF 'return 301 "https://new.test$request_uri";' "$v" 2>/dev/null && pass "app redirect keeps path" || fail "app redirect wrong"
grep -qF 'server_name shop.test www.shop.test;' "$v" 2>/dev/null && pass "all names redirect in one hop" || fail "names wrong"
grep -qF '/.well-known/acme-challenge/' "$v" 2>/dev/null && pass "ACME stays public" || fail "ACME missing"
grep -qF 'location ^~ /api/' "$v" 2>/dev/null && grep -qF 'location = /old' "$v" \
    && pass "rules still live under app redirect" || fail "rules dropped under app redirect"
grep -q 'fastcgi_pass' "$v" 2>/dev/null && fail "redirect vhost still serves PHP" || pass "redirect vhost serves no PHP"
[[ "$(grep -o '{' "$v" | wc -l)" == "$(grep -o '}' "$v" | wc -l)" ]] && pass "braces balanced" || fail "unbalanced braces"

echo "-- normal vhost with rules"
jq '.shop.redirect.enabled = false' "${TMP}/apps.json" > "${TMP}/a2" && mv "${TMP}/a2" "${TMP}/apps.json"
bash -c "$H _create_nginx_vhost shop shop.test 8.4" >/dev/null 2>&1
grep -q 'fastcgi_pass' "$v" && grep -qF 'location ^~ /api/' "$v" && grep -qF 'location ^~ /blog/' "$v" \
    && pass "disabled app redirect: app served, rules rendered" || fail "disabled app redirect vhost wrong"
[[ "$(grep -o '{' "$v" | wc -l)" == "$(grep -o '}' "$v" | wc -l)" ]] && pass "braces balanced" || fail "unbalanced braces"

echo "-- validation"
v_ok()  { bash -c "$H $1" >/dev/null 2>&1 && pass "accepts: $2" || fail "rejects: $2"; }
v_bad() { bash -c "$H $1" >/dev/null 2>&1 && fail "accepts: $2" || pass "rejects: $2"; }
v_ok  "_routes_valid_path /ok/path-1_2.x"     "plain path"
for p in '/a;b' '/a b' '/a\$b' '/a\"b' '/a{b' '/a..b' '/x//y'; do
    v_bad "_routes_valid_path '$p'" "path $p"
done
v_bad "_routes_valid_source_path /a%20b"       "encoded source path"
v_ok  "_routes_valid_url 'https://new.test/a?b=1#c'" "URL with query"
for u in 'https://x.test/\$1' 'http://x.test/a;b' 'http://h:99999' 'ftp://x.test' 'https://x.test\\\\y'; do
    v_bad "_routes_valid_url '$u'" "URL $u"
done
v_bad "_routes_valid_upstream 'http://h.test/?q'" "upstream with query"
v_bad "_routes_valid_upstream http://h:0"        "upstream port 0"
v_bad "ARG_301=true ARG_302=true _routes_parse_code" "two codes"
v_bad "ARG_code=303 _routes_parse_code"           "code 303"
[[ "$(bash -c "$H _routes_parse_code")" == "301" ]] && pass "default code 301" || fail "default code not 301"

v_bad "_routes_check_path shop / redirect"          "redirect on /"
v_bad "_routes_check_path shop /.well-known/acme-challenge/ proxy" "ACME path"
v_bad "_routes_check_path shop /cipi/webhook redirect" "webhook path"
v_bad "_routes_check_path shop /app/ proxy"          "Reverb path on Reverb app"
v_bad "_routes_check_path shop /api/ redirect"       "redirect on a proxied prefix"
v_bad "_routes_check_path shop /promo redirect"      "exact path under a prefix rule"
v_ok  "_routes_check_path shop /api/ proxy"          "same proxy prefix (update)"
v_ok  "_routes_check_path shop /new-thing/ redirect" "free prefix"
v_ok  "_routes_host_is_app shop www.shop.test"       "alias is the app"
v_bad "_routes_host_is_app shop blog.test"           "other host is the app"
v_ok  "_routes_reserved_local_port shop 8001"        "other app's Octane port reserved"
v_ok  "_routes_reserved_local_port shop 3306"        "MariaDB port reserved"
v_bad "_routes_reserved_local_port shop 3000"        "free port reserved"

echo "-- commands (nginx mocked)"
cp "${TMP}/apps.json" "${TMP}/apps.orig"
M="nginx() { :; }; _nginx_reapply_ssl() { :; };"
v_bad "$M redirect_command add shop /docs/ /docs/v2/"            "prefix redirect into itself"
v_bad "$M redirect_command set shop --to=https://www.shop.test"  "app redirect to itself"
v_bad "$M proxy_command add shop /x/ https://shop.test"          "proxy to itself"
v_bad "$M proxy_command add shop /x/ http://10.0.0.5/v1"         "upstream path without --strip-prefix"
v_bad "$M proxy_command add shop /x/ http://127.0.0.1:6379"      "Valkey without --force"
v_ok  "$M redirect_command add shop /docs/ /documentation/ --302" "add prefix redirect"
jq -e '.shop.redirects | any(.from == "/docs/" and .to == "/documentation/" and .code == 302)' "${TMP}/apps.json" >/dev/null \
    && pass "redirect saved" || fail "redirect not saved"
v_ok  "$M proxy_command add shop gw http://10.0.0.9:81 --timeout=090" "add proxy (prefix normalised)"
jq -e '.shop.proxies | any(.prefix == "/gw/" and .timeout == 90)' "${TMP}/apps.json" >/dev/null \
    && pass "proxy saved as /gw/, timeout 90" || fail "proxy not saved/normalised"
v_ok  "$M redirect_command disable shop; true" "disable app redirect"
v_ok  "$M redirect_command set shop --to=https://moved.test --no-path --307" "set app redirect"
jq -e '.shop.redirect == {"enabled":true,"to":"https://moved.test","code":307,"keep_path":false}' "${TMP}/apps.json" >/dev/null \
    && pass "app redirect saved" || fail "app redirect wrong: $(jq -c .shop.redirect "${TMP}/apps.json")"

before=$(jq -c .shop "${TMP}/apps.json")
v_bad "nginx() { :; }; _nginx_reapply_ssl() { return 1; }; proxy_command add shop /bad/ http://10.0.0.7" "nginx refuses → exit 1"
[[ "$(jq -c .shop "${TMP}/apps.json")" == "$before" ]] && pass "apps.json reverted after nginx refusal" || fail "apps.json not reverted"
v_bad "nginx() { return 1; }; proxy_command add shop /bad/ http://10.0.0.7" "refuses when nginx is already broken"
v_ok  "$M redirect_command remove shop docs/" "remove redirect"
v_ok  "$M proxy_command remove shop /gw" "remove proxy"
v_ok  "$M routes_list redirect shop --json | jq -e '.redirect.to'" "list --json"

echo "-- docs"
grep -q 'cipi compliance' "${ROOT}/README.md" && pass "README documents cipi compliance" || fail "README omits cipi compliance"
grep -q 'cipi compliance' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG documents cipi compliance" || fail "CHANGELOG omits cipi compliance"

grep -q 'cipi redirect' "${ROOT}/README.md" && grep -q 'cipi proxy' "${ROOT}/README.md" \
    && pass "README documents redirect and proxy" || fail "README omits redirect/proxy"
grep -q 'cipi redirect' "${ROOT}/CHANGELOG.md" && grep -q 'cipi proxy' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG documents redirect and proxy" || fail "CHANGELOG omits redirect/proxy"

echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
