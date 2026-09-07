#!/bin/bash
# Local regression checks for 5.1.3 — cipi ini list unbound _INI_SOURCE.
# Run from repo root: bash tests/verify-5.1.3.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "=== Cipi 5.1.3 regression checks ==="

# ── Release plumbing ────────────────────────────────────────────
[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.1.3" ]] \
    && pass "version.md is 5.1.3" || fail "version.md is not 5.1.3"
grep -q '^## \[5.1.3\]' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.1.3 entry" || fail "CHANGELOG has no 5.1.3 entry"
[[ ! -f "${LIB}/migrations/5.1.3.sh" ]] \
    && pass "no 5.1.3 migration (code-only fix)" || fail "stray 5.1.3 migration"
[[ ! -f "${LIB}/migrations/5.1.4.sh" ]] \
    && pass "no stray 5.1.4 migration" || fail "stray 5.1.4 migration"

# ── Syntax ──────────────────────────────────────────────────────
bash -n "${LIB}/ini.sh" && pass "syntax ini.sh" || fail "syntax ini.sh"

# ── The subshell form must not come back ────────────────────────
if grep -nE '\$\(_ini_effective' "${LIB}/ini.sh"; then
    fail "_ini_effective is still called via \$() — that discards _INI_SOURCE under set -u"
else
    pass "_ini_effective is not called via \$()"
fi
grep -q '_INI_VALUE=' "${LIB}/ini.sh" \
    && pass "_ini_effective writes _INI_VALUE" || fail "_INI_VALUE is not set"
grep -q '_ini_effective "\$k" "\$app" "\$ver"' "${LIB}/ini.sh" \
    && pass "_ini_list calls _ini_effective in the current shell" \
    || fail "_ini_list does not call _ini_effective in the current shell"

# ── Runtime: listing every catalog key under set -u ─────────────
# This is the crash: header printed, then `_INI_SOURCE: unbound variable`
# on the first key, because val=$(_ini_effective) ran in a subshell.
# Do not wrap this heredoc in $() — bash would close the substitution on the
# first function's `()`.
LIB="$LIB" bash -euo pipefail >"${TMP}/list.out" <<'EOF'
BOLD=''; DIM=''; NC=''; CYAN=''; GREEN=''
_ini_read_app() { echo ""; }
_ini_read_global() {
    case "$3" in
        memory_limit|upload_max_filesize|post_max_size) echo "256M" ;;
        *) echo "" ;;
    esac
}
eval "$(sed -n '/^_ini_key_catalog()/,/^}/p; /^_ini_effective()/,/^}/p' "${LIB}/ini.sh")"
count=0
while IFS='|' read -r k t d; do
    [[ -n "$k" ]] || continue
    _ini_effective "$k" "" "8.5"
    val="$_INI_VALUE"
    : "$_INI_SOURCE"
    printf '%s\t%s\t%s\n' "$k" "${val:--}" "$_INI_SOURCE"
    count=$((count + 1))
done < <(_ini_key_catalog)
echo "COUNT=$count"
EOF
list_rc=$?
if [[ "$list_rc" -eq 0 ]]; then
    pass "listing catalog keys under set -u does not unbound _INI_SOURCE"
else
    fail "listing catalog keys under set -u still crashes"
fi

count=$(awk -F= '/^COUNT=/{print $2}' "${TMP}/list.out")
[[ "${count:-0}" -gt 20 ]] && pass "listed ${count} catalog keys" || fail "listed too few keys: ${count:-none}"
grep -q $'memory_limit\t256M\tglobal' "${TMP}/list.out" \
    && pass "global memory_limit is reported as SET BY global" \
    || fail "global memory_limit source is wrong: $(grep '^memory_limit' "${TMP}/list.out" || true)"
grep -q $'max_execution_time\t-\tunset' "${TMP}/list.out" \
    && pass "a key with no layer is reported as unset" \
    || fail "unset key source is wrong: $(grep '^max_execution_time' "${TMP}/list.out" || true)"

# App override still wins, still in the current shell.
LIB="$LIB" bash -euo pipefail >"${TMP}/app.out" <<'EOF'
_ini_read_app() { [[ "$2" == "memory_limit" ]] && echo "512M"; }
_ini_read_global() { echo "256M"; }
eval "$(sed -n '/^_ini_effective()/,/^}/p' "${LIB}/ini.sh")"
_ini_effective memory_limit myapp 8.5
printf '%s %s\n' "$_INI_VALUE" "$_INI_SOURCE"
EOF
app_out=$(cat "${TMP}/app.out")
[[ "$app_out" == "512M app:myapp" ]] \
    && pass "app override sets _INI_SOURCE in the current shell" \
    || fail "app override: ${app_out}"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
