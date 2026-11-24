#!/bin/bash
# 5.13.1:
#  - `cipi db switch mysql` ended in silence after "Checking the MySQL
#    packages..." (Ubuntu 24.04 and 26.04): `apt-cache policy | awk '…exit'`,
#    with gawk — Ubuntu Server's awk — reading lines as they come, killed
#    apt-cache with SIGPIPE and pipefail made set -e stop the command;
#  - a command that fails where nothing checks it now says where cipi stopped;
#  - `cipi help` lists every command like `php artisan list`.
# (The whole switch runs again under set -euo pipefail with these apt-cache
# and awk in tests/verify-5.13.0.sh.) Run from repo root: bash tests/verify-5.13.1.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0; FAIL=0
pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
TMP=$(mktemp -d) && [[ -n "$TMP" && -d "$TMP" ]] || exit 1
trap 'rm -rf "${TMP:?}"' EXIT
echo "=== Cipi 5.13.1 regression checks ==="

v=$(tr -d "[:space:]" < "${ROOT}/version.md"); [[ "$(printf "%s\n%s\n" 5.13.1 "$v" | sort -V | head -1)" == 5.13.1 ]] && pass "version.md >= 5.13.1" || fail "version.md"
grep -q '^## \[5.13.1\]' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG 5.13.1" || fail "CHANGELOG"
for f in "${ROOT}/cipi" "${LIB}/db.sh" "${LIB}/stack-upgrade.sh" "${LIB}/crowdsec.sh" "${LIB}/cipi-app-deploy.sh" "${LIB}/deploy.sh" "${LIB}/common.sh"; do
    bash -n "$f" && pass "$(basename "$f") parses" || fail "$(basename "$f") parse"
done

# ── apt as it writes, awk as gawk reads ──────────────────────
B="${TMP}/bin"; mkdir -p "$B"
cat > "${B}/apt-cache" <<'STUB'
#!/bin/bash
echo "${2:-pkg}:"; echo "  Installed: (none)"; echo "  Candidate: 8.4.11-0ubuntu0.26.04.1"
sleep 0.2; echo "  Version table:"; echo "     8.4.11-0ubuntu0.26.04.1 500"
STUB
if command -v gawk >/dev/null 2>&1; then ln -sf "$(command -v gawk)" "${B}/awk"
else printf '#!/bin/bash\nexec mawk -W interactive "$@"\n' > "${B}/awk"; fi
chmod +x "${B}/"*

o=$(PATH="${B}:${PATH}" bash -c 'set -euo pipefail; c=$(apt-cache policy mysql-server 2>/dev/null | awk "/Candidate:/{print \$2; exit}"); echo "reached $c"' 2>&1); r=$?
[[ $r -eq 141 && "$o" != *reached* ]] && pass "the stubs reproduce 5.13.0: awk exits, apt-cache gets SIGPIPE, set -e stops at 141" || fail "no reproduction (exit ${r}): ${o}"

RUNC=$(printf 'set -euo pipefail\nRED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""; BOLD=""\nexport CIPI_LIB=%q CIPI_CONFIG=%q CIPI_LOG=%q\nsource "$CIPI_LIB/vault.sh" 2>/dev/null; source "$CIPI_LIB/common.sh"\n' "$LIB" "${TMP}/cfg" "${TMP}/log")
mkdir -p "${TMP}/cfg" "${TMP}/log"
o=$(PATH="${B}:${PATH}" bash -c "${RUNC}"$'\nsource "$CIPI_LIB/db.sh"; c=$(_db_apt_candidate mysql-server); echo "reached $c"' 2>&1); r=$?
[[ $r -eq 0 && "$o" == "reached 8.4.11-0ubuntu0.26.04.1" ]] && pass "_db_apt_candidate reads apt whole: the candidate, no SIGPIPE" || fail "candidate (exit ${r}): ${o}"
o=$(PATH="${B}:${PATH}" bash -c "${RUNC}"$'\nsource "$CIPI_LIB/stack-upgrade.sh"; c=$(_stack_upgrade_candidate nginx); echo "reached $c"' 2>&1); r=$?
[[ $r -eq 0 && "$o" == "reached 8.4.11-0ubuntu0.26.04.1" ]] && pass "cipi service upgrade / autoupdate: same for the stack candidates" || fail "stack candidate (exit ${r}): ${o}"
! grep -rnE "\|\s*awk\s+(-[a-zA-Z]+\s+\S+\s+)*'[^']*\bexit\b[^']*'" "${ROOT}/cipi" "${LIB}"/*.sh | grep -qvE '^[^:]+:[0-9]+:\s*#' \
    && pass "no awk that exits early at the end of a pipeline left" || fail "awk … exit: $(grep -rnE "\|\s*awk\s+'[^']*\bexit\b" "${LIB}"/*.sh | head -3)"
grep -q "apt-cache policy mysql-server 2>&1 | sed -n '1,6s/^/  /p'" "${LIB}/db.sh" && pass "no candidate: what apt says is shown" || fail "no apt output on refusal"

# ── a stop nobody checked is reported ────────────────────────
C="${TMP}/c"; mkdir -p "${C}/cfg" "${C}/log"; cp -r "${LIB}" "${C}/lib"; echo 5.13.1 > "${C}/cfg/version"
sed -e "s#/opt/cipi/lib#${C}/lib#; s#\"/etc/cipi\"#\"${C}/cfg\"#; s#\"/var/log/cipi\"#\"${C}/log\"#" "${ROOT}/cipi" > "${C}/cipi"
cat > "${C}/lib/db.sh" <<'EOF'
db_command() {
    case "${1:-}" in
        pipe)    step "Checking..."; local c; c=$(printf 'a\n' | false | cat); echo "not reached $c" ;;
        err)     error "Something is wrong"; exit 1 ;;
        guarded) local x; x=$(false) || true; x=$(grep nope /dev/null || true); echo "guarded ok" ;;
        cond)    if helper; then :; fi; helper || true; echo "cond ok" ;;
        sub)     local z; z=$(false; echo after); echo "sub ok" ;;
        ok)      echo fine ;;
    esac
}
helper() { false; }
EOF
o=$(bash "${C}/cipi" db pipe 2>&1); r=$?
[[ $r -ne 0 && "$o" == *"Stopped unexpectedly at db.sh:3 in db_command() (exit 1)"* && "$o" != *"not reached"* ]] \
    && pass "an unchecked failure says file, line, function and exit status" || fail "trap: exit ${r}: ${o}"
o=$(bash "${C}/cipi" db err 2>&1); r=$?
[[ $r -eq 1 && "$o" == *"Something is wrong"* && "$o" != *"unexpectedly"* ]] && pass "…not after an error already printed" || fail "after error: ${o}"
for c in guarded cond sub ok; do
    o=$(bash "${C}/cipi" db "$c" 2>&1); r=$?
    [[ $r -eq 0 && "$o" != *"unexpectedly"* ]] && pass "…not for a failure that is checked or inside \$(…) (${c})" || fail "${c}: exit ${r}: ${o}"
done
grep -q '_CIPI_ERROR_SHOWN=1' "${LIB}/common.sh" && pass "error() marks that the message was given" || fail "error flag"

# ── cipi help: like php artisan list ─────────────────────────
o=$(COLUMNS=120 bash "${C}/cipi" help 2>&1); r=$?
plain=$(sed 's/\x1b\[[0-9;]*m//g' <<< "$o")
[[ $r -eq 0 ]] && grep -q '^Usage:$' <<< "$plain" && grep -q '^Options:$' <<< "$plain" && grep -q '^Available commands:$' <<< "$plain" \
    && pass "cipi help: Usage, Options, Available commands" || fail "help sections (exit ${r}): $(head -20 <<< "$plain")"
grep -q $'\033\\[1;33mUsage:' <<< "$o" && grep -q $'^ \033\\[1;33mdb\033\\[0m$' <<< "$o" && grep -q $'^  \033\\[0;32mdb switch' <<< "$o" \
    && pass "…titles and namespaces in yellow, commands in green" || fail "help colours"
awk '/^ db$/{f=1; next} f && /^ [a-z]/{exit} f' <<< "$plain" | grep -q '^  db switch  *Replace the server on port 3306' \
    && pass "…db switch listed under db, with its description" || fail "db switch missing: $(awk '/^ db$/,/^ search$/' <<< "$plain")"
cmds=$(sed -n '/^Available commands:$/,$p' <<< "$plain")
n=$(grep -c '^  [a-z]' <<< "$cmds")
(( n > 300 )) && pass "…every command of every topic (${n})" || fail "only ${n} commands"
! grep -q '^  cipi ' <<< "$cmds" && ! grep -qE '^  [a-z][^ ]*( [a-z|-]+)* +.*\[--|^  [a-z-]+ <' <<< "$cmds" && pass "…names without 'cipi', options or placeholders" || fail "raw syntax in the list"
for c in 'deploy --rollback' 'app limits' 'backup profile add' 'zt hostname add --gui' 'status'; do
    grep -qE "^  ${c}  " <<< "$plain" || { fail "missing: ${c}"; continue; }
done && pass "…deploy --rollback, app limits (under app), backup profile add, zt hostname add --gui, status"
[[ "$(awk '/^ app$/{f=1; next} f && /^ [a-z]/{exit} f' <<< "$plain" | grep -c '^  app limits')" == 1 ]] && pass "…a command in two topics is listed once, in its own namespace" || fail "app limits placement"
[[ "$(grep -c '^  ' <<< "$plain")" == "$(grep '^  ' <<< "$plain" | sort -u | wc -l)" ]] && pass "…no line twice" || fail "duplicates"
o=$(bash "${C}/cipi" help db 2>&1); plain=$(sed 's/\x1b\[[0-9;]*m//g' <<< "$o")
grep -q 'cipi db switch <mysql|mariadb>' <<< "$plain" && grep -q $'\033\\[0;32mcipi db switch\033\\[0m\033\\[2m <mysql|mariadb>' <<< "$o" \
    && pass "cipi help db: the command in green, its arguments dimmed" || fail "topic view: $(head -20 <<< "$plain")"
o=$(bash "${C}/cipi" help all 2>&1); r=$?
[[ $r -eq 0 ]] && grep -q 'cipi credentials export' <<< "$(sed 's/\x1b\[[0-9;]*m//g' <<< "$o")" && pass "cipi help all: every topic (credentials included)" || fail "help all (exit ${r})"
o=$(bash "${C}/cipi" help nope 2>&1); r=$?
[[ $r -eq 1 && "$o" == *"Unknown help topic: nope"* && "$o" != *"unexpectedly"* ]] && pass "unknown topic: one error, exit 1" || fail "unknown topic: ${o}"
o=$(bash "${C}/cipi" db --help 2>&1); grep -q 'cipi db switch' <<< "$(sed 's/\x1b\[[0-9;]*m//g' <<< "$o")" && pass "cipi db --help: the topic" || fail "db --help"
grep -q 'show_help | less -R -F -X || true' "${ROOT}/cipi" && pass "a terminal gets it through less; quitting early is not a failure" || fail "pager"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
