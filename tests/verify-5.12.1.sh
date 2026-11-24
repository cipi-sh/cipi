#!/bin/bash
# 5.12.1: release numbering after the move from Deployer 6 to 8 (5.10.0).
# Deployer 6 never wrote .dep/latest_release or .dep/releases_log, so on
# Deployer 8 every app started again at release 1 next to the old releases
# and stopped at "Release name "N" already exists". Checks the release_name
# appended to deploy.php (run with run()/within() as Deployer 8 runs them:
# `cd <cwd> && (cmd)` in bash, trimmed, exit status checked), the hook that
# appends it, and the repair of an app's .dep state.
# Run from repo root: bash tests/verify-5.12.1.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0; FAIL=0
pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
TMP=$(mktemp -d) && [[ -n "$TMP" && -d "$TMP" ]] || exit 1
trap 'rm -rf "${TMP:?}"' EXIT
echo "=== Cipi 5.12.1 regression checks ==="

v=$(tr -d "[:space:]" < "${ROOT}/version.md"); [[ "$(printf "%s\n%s\n" 5.12.1 "$v" | sort -V | head -1)" == 5.12.1 ]] && pass "version.md >= 5.12.1" || fail "version.md"
grep -q '^## \[5.12.1\]' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG 5.12.1" || fail "CHANGELOG"
bash -n "${LIB}/migrations/5.12.1.sh" && pass "migration parses" || fail "migration parse"
bash -n "${LIB}/common.sh" && pass "common.sh parses" || fail "common.sh parse"
grep -q 'deployer_release_name_ensure_hook' "${LIB}/app.sh" && grep -q 'deployer_release_name_ensure_hook' "${LIB}/sync.sh" \
    && pass "new and imported deploy.php get the hook" || fail "hook not called by app.sh / sync.sh"

# ── release_name ─────────────────────────────────────────────
if command -v php >/dev/null 2>&1; then
    cat > "${TMP}/harness.php" <<'PHP'
<?php
namespace Deployer;
$GLOBALS['cfg'] = ['deploy_path' => $argv[1]]; $GLOBALS['wp'] = null;
function set($k, $v) { $GLOBALS['cfg'][$k] = $v; }
function parse($s) { return preg_replace_callback('/\{\{(\w+)\}\}/', fn($m) => $GLOBALS['cfg'][$m[1]], $s); }
function within($p, $cb) { $o = $GLOBALS['wp']; $GLOBALS['wp'] = parse($p); try { return $cb(); } finally { $GLOBALS['wp'] = $o; } }
function run($cmd) {
    exec('bash -c ' . escapeshellarg('cd ' . escapeshellarg($GLOBALS['wp']) . ' && (' . $cmd . ')'), $out, $rc);
    if ($rc !== 0) { fwrite(STDERR, "exit $rc: $cmd\n"); exit(9); }
    return rtrim(implode("\n", $out));
}
require $argv[2];
echo $GLOBALS['cfg']['release_name']();
PHP
    { echo '<?php'; echo 'namespace Deployer;'; cat "${LIB}/deployer/release-name.php"; } > "${TMP}/snippet.php"
    php -l "${TMP}/snippet.php" >/dev/null 2>&1 && pass "release-name.php is valid PHP" || fail "release-name.php does not parse"
    rn() {   # <latest_release|""> <dirs> <want> <label>
        local dp="${TMP}/rn.$RANDOM" got
        mkdir -p "${dp}/.dep" "${dp}/releases"
        for d in $2; do mkdir -p "${dp}/releases/${d}"; done
        [[ -n "$1" ]] && echo "$1" > "${dp}/.dep/latest_release"
        got=$(php "${TMP}/harness.php" "$dp" "${TMP}/snippet.php" 2>&1)
        [[ "$got" == "$3" ]] && pass "$4: release ${got}" || fail "$4: got '${got}', want $3"
    }
    rn 1  "1 2 59 60 61"    62 "Deployer 6 releases up to 61, latest_release 1 (the report)"
    rn 3  "1 2 3 50"        51 "Deployer 6 release 50 left behind, latest_release 3"
    rn "" "59 60 61"        62 "no latest_release yet, Deployer 6 releases"
    rn 61 "59 60 61"        62 "Deployer 7/8 as usual"
    rn 70 "68 69 70"        71 "Deployer 7/8 after cleanup"
    rn "" ""                1  "first deploy"
    rn 5  "4 5 bak 12x"     6  "directories that are not numbers are ignored"
else
    echo "  (php not installed: release_name not run)"
fi

# ── hook and repair ──────────────────────────────────────────
# common.sh with /home/<app> under $TMP; file operations run as the current
# user (they run as the app user on a server).
cp -r "$LIB" "${TMP}/lib" && sed -i "s|/home/|${TMP}/home/|g" "${TMP}/lib/common.sh"
export CIPI_LIB="$LIB" CIPI_CONFIG="${TMP}/etc" CIPI_LOG="${TMP}/log"
mkdir -p "$CIPI_CONFIG" "$CIPI_LOG"
H="${TMP}/home/demoapp"
mkdir -p "${H}/releases/1" "${H}/releases/2" "${H}/releases/59" "${H}/releases/60" "${H}/releases/61" "${H}/.dep" "${H}/.deployer"
printf '20261119101500,59\n20261120093000,60\n20261121113600,61\n' > "${H}/.dep/releases"
echo 1 > "${H}/.dep/latest_release"
echo '{"created_at":"2026-11-23T09:15:02+0000","release_name":"1","user":"dev","target":"main"}' > "${H}/.dep/releases_log"
touch -d '2026-03-02 10:00' "${H}/releases/2"
printf '<?php\nnamespace Deployer;\nrequire '"'"'recipe/laravel.php'"'"';\n' > "${H}/.deployer/deploy.php"
cat > "${TMP}/run.sh" <<EOF
source "${TMP}/lib/common.sh"
app_get() { [[ "\$2" == custom ]] && echo "\${CUSTOM:-false}"; }
app_as() { shift; ( cd / && "\$@" ); }
_app_own_check() { :; }
"\$@"
EOF
c() { bash "${TMP}/run.sh" "$@"; }

o=$(c deployer_release_state_repair demoapp 2>&1); r=$?
[[ $r -eq 0 ]] && pass "repair exits 0" || fail "repair exit ${r}: ${o}"
[[ "$(cat "${H}/.dep/latest_release")" == 61 ]] && pass "latest_release 1 → 61" || fail "latest_release is $(cat "${H}/.dep/latest_release")"
grep -q 'next release: 62' <<< "$o" && pass "says the next release" || fail "output: ${o}"
order=$(jq -r '.release_name' "${H}/.dep/releases_log" | paste -sd' ' -)
[[ "$order" == "2 59 60 61 1" ]] && pass "releases_log: Deployer 6 releases first, by date, then Deployer 8's ($order)" || fail "releases_log order: ${order}"
[[ "$(jq -r 'select(.imported != null) | .release_name' "${H}/.dep/releases_log" | paste -sd' ' -)" == "2 59 60 61" ]] && pass "imported lines are marked" || fail "imported marker"
php_ok=yes
if command -v php >/dev/null 2>&1; then
    php -r 'foreach (file($argv[1]) as $l) { $j = json_decode($l, true); if (!$j || !\DateTime::createFromFormat(\DateTimeInterface::ISO8601, $j["created_at"])) exit(1); }' "${H}/.dep/releases_log" || php_ok=no
fi
[[ "$php_ok" == yes ]] && pass "every created_at reads as Deployer's ISO8601" || fail "created_at Deployer cannot read"
[[ "$(jq -r 'select(.release_name == "61") | .created_at' "${H}/.dep/releases_log")" == "$(date -u -d '2026-11-21 11:36:00' +%Y-%m-%dT%H:%M:%S+0000)" ]] \
    && pass "date from Deployer 6's own list" || fail "date of 61"
ls -A "${H}/.dep" | grep -q cipi-import && fail "temporary files left in .dep" || pass "nothing temporary left in .dep"
sum=$(md5sum "${H}/.dep/releases_log" "${H}/.dep/latest_release")
o=$(c deployer_release_state_repair demoapp 2>&1)
[[ -z "$o" && "$(md5sum "${H}/.dep/releases_log" "${H}/.dep/latest_release")" == "$sum" ]] && pass "second run changes nothing" || fail "second run: ${o}"
[[ -L "${H}/current" ]] || ln -s releases/1 "${H}/current"
[[ "$(readlink "${H}/current")" == releases/1 && -d "${H}/releases/2" && -d "${H}/releases/59" ]] && pass "no release moved or deleted" || fail "releases changed"

echo 1 > "${H}/.dep/latest_release"; touch "${H}/.dep/deploy.lock"
o=$(c deployer_release_state_repair demoapp 2>&1)
[[ "$(cat "${H}/.dep/latest_release")" == 1 ]] && grep -q skipped <<< "$o" && pass "a locked app is left alone" || fail "locked: ${o}"
rm -f "${H}/.dep/deploy.lock"
o=$(CUSTOM=true c deployer_release_state_repair demoapp 2>&1)
[[ -z "$o" && "$(cat "${H}/.dep/latest_release")" == 1 ]] && pass "custom apps are skipped" || fail "custom: ${o}"

c deployer_release_name_ensure_hook demoapp && c deployer_release_name_ensure_hook demoapp \
    && [[ "$(grep -c 'cipi:release-name' "${H}/.deployer/deploy.php")" == 1 ]] && pass "hook appended once" || fail "hook"
if command -v php >/dev/null 2>&1; then
    php -l "${H}/.deployer/deploy.php" >/dev/null 2>&1 && pass "deploy.php still valid PHP" || fail "deploy.php does not parse"
fi
printf '<?php\nnamespace Deployer;\nrequire '"'"'recipe/common.php'"'"';\n?>\n' > "${H}/.deployer/deploy.php"
c deployer_release_name_ensure_hook demoapp && fail "a deploy.php closed with ?> was appended to" || pass "a deploy.php closed with ?> is refused"

grep -q 'select(.imported == null)' "${LIB}/compliance.sh" && pass "compliance skips imported lines" || fail "compliance"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
