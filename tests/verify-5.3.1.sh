#!/bin/bash
# Local regression checks for 5.3.1 — `cipi compliance` (evidence report).
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

echo "-- docs"
grep -q 'cipi compliance' "${ROOT}/README.md" && pass "README documents cipi compliance" || fail "README omits cipi compliance"
grep -q 'cipi compliance' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG documents cipi compliance" || fail "CHANGELOG omits cipi compliance"

echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
