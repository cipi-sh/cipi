#!/bin/bash
# 5.11.2: the panel whitelist is split into rules of at most 40 commands
# (sudo-rs 0.2.13 on Ubuntu 26.04 refuses a list of ~128 items: "too many
# items in list"), and checked with `visudo -c -f` before it is put in place;
# a refused whitelist never replaces the previous one. visudo is a stub in
# front of PATH: one with sudo-rs's limit, one that refuses every file; the
# real visudo checks the file too when it is installed.
# Run from repo root: bash tests/verify-5.11.2.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0; FAIL=0
pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
TMP=$(mktemp -d) && [[ -n "$TMP" && -d "$TMP" ]] || exit 1
trap 'rm -rf "${TMP:?}"' EXIT
echo "=== Cipi 5.11.2 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.11.2" ]] && pass "version.md is 5.11.2" || fail "version.md"
grep -q '^## \[5.11.2\]' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG 5.11.2" || fail "CHANGELOG"
bash -n "${LIB}/migrations/5.11.2.sh" && pass "migration parses" || fail "migration parse"
grep -rn 'visudo -cqf' "${LIB}/cipi-api-sudoers.sh" "${LIB}/self-update.sh" "${LIB}/migrations/5.11.0.sh" >/dev/null \
    && fail "visudo -cqf still used where the whitelist is written" || pass "no visudo -cqf where the whitelist is written"

mkdir -p "${TMP}/bin" "${TMP}/sudoers.d"
sed "s|/etc/sudoers.d/cipi-api|${TMP}/sudoers.d/cipi-api|g" "${LIB}/cipi-api-sudoers.sh" > "${TMP}/sudoers.sh"
cat > "${TMP}/bin/visudo" <<'V'
#!/bin/bash
# like sudo-rs 0.2.13: no -q; a list of 100 items or more is refused
for a in "$@"; do [[ "$a" == -*q* ]] && { echo "visudo: unexpected argument '$a'" >&2; exit 1; }; done
[[ "$1" == -c && "$2" == -f && -f "$3" ]] || exit 1
awk '/^www-data /{n=0} /\/(usr\/local\/bin|bin)\//{n++; if (n >= 100) bad=1} END{exit bad}' "$3" || { echo "$3:128:32: syntax error: too many items in list" >&2; exit 1; }
grep -q 'cipi metrics overview' "$3" && { echo "$3: parsed OK"; exit 0; }
echo "$3: syntax error near line 1" >&2; exit 1
V
chmod +x "${TMP}/bin/visudo"
echo "old whitelist" > "${TMP}/sudoers.d/cipi-api"
o=$(PATH="${TMP}/bin:${PATH}" bash -c "source '${TMP}/sudoers.sh'; write_cipi_api_sudoers" 2>&1); r=$?
[[ $r -eq 0 ]] && grep -q 'cipi metrics overview' "${TMP}/sudoers.d/cipi-api" && pass "sudo-rs visudo: the new whitelist is written" || fail "not written (exit ${r}): ${o}"
[[ "$(stat -c '%a' "${TMP}/sudoers.d/cipi-api")" == "440" ]] && pass "0440" || fail "mode $(stat -c '%a' "${TMP}/sudoers.d/cipi-api")"
W="${TMP}/sudoers.d/cipi-api"
rules=$(grep -c '^www-data ALL=(root) NOPASSWD: ' "$W")
max=$(awk '/^www-data /{if(n>m)m=n; n=0} /\/(usr\/local\/bin|bin)\//{n++} END{if(n>m)m=n; print m}' "$W")
(( rules >= 3 && max <= 40 )) && pass "split into ${rules} rules of at most 40 commands" || fail "rules=${rules} max=${max}"
want=$(sed -n "/<<'SUDOEOF'/,/^SUDOEOF/p" "${LIB}/cipi-api-sudoers.sh" | grep -oE '/(usr/local/bin|bin)/[^,\\]*[^,\\[:space:]]' | sort)
got=$(grep -oE '/(usr/local/bin|bin)/[^,\\]*[^,\\[:space:]]' "$W" | sort)
[[ -n "$want" && "$want" == "$got" ]] && pass "every command of the whitelist is in the written rules ($(wc -l <<< "$got"))" || fail "commands differ: $(diff <(echo "$want") <(echo "$got") | head -5)"
tail -1 "$W" | grep -q ', \\$' && fail "last line ends with a continuation" || pass "each rule ends without a dangling comma"
if [[ -x /usr/sbin/visudo || -x /usr/bin/visudo ]]; then
    "$(command -v -p visudo 2>/dev/null || echo /usr/sbin/visudo)" -c -f "$W" >/dev/null 2>&1 && pass "the real visudo accepts it" || fail "the real visudo refuses it"
fi
ls "${TMP}/sudoers.d" | grep -q '\.' && fail "temporary file left in sudoers.d" || pass "nothing temporary in sudoers.d"

cat > "${TMP}/bin/visudo" <<'V'
#!/bin/bash
echo ">>> ${3:-x}: syntax error, unexpected '*', line 42 <<<" >&2; exit 1
V
echo "old whitelist" > "${TMP}/sudoers.d/cipi-api"
o=$(PATH="${TMP}/bin:${PATH}" bash -c "source '${TMP}/sudoers.sh'; write_cipi_api_sudoers" 2>&1); r=$?
[[ $r -ne 0 && "$(cat "${TMP}/sudoers.d/cipi-api")" == "old whitelist" ]] && pass "refused: the previous whitelist stays" || fail "refused file replaced the old one"
[[ "$o" == *"line 42"* ]] && pass "visudo's own message is shown" || fail "message hidden: ${o}"

echo ""; echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
