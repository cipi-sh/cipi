#!/bin/bash
# Local regression checks for 5.7.1 — PHP advisory of 2026-10-23
# (CVE-2026-115560): Octane apps load the FPM pool hardening through
# PHP_INI_SCAN_DIR, and migration 5.7.1 rewrites existing Octane programs.
# Run from repo root: bash tests/verify-5.7.1.sh
# Optional: CIPI_TEST_FRANKENPHP=/path/to/frankenphp also checks that a real
# FrankenPHP binary picks the settings up.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "=== Cipi 5.7.1 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.7.1" ]] \
    && pass "version.md is 5.7.1" || fail "version.md is not 5.7.1"
grep -q '^## \[5.7.1\]' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.7.1 entry" || fail "CHANGELOG has no 5.7.1 entry"
grep -q 'CVE-2026-115560' "${ROOT}/CHANGELOG.md" && grep -q 'lib/migrations/5.7.1.sh' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG names the CVE and the migration" || fail "CHANGELOG content"
for f in common.sh migrations/5.7.1.sh; do
    bash -n "${LIB}/${f}" && pass "${f} parses" || fail "${f} does not parse"
done

TMP=$(mktemp -d) || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "${TMP:?}"' EXIT

extract() { sed -n "/^${2}() {/,/^}/p" "${LIB}/${1}"; }

# The real generators, pointed at a scratch tree instead of /etc.
INI_DIR="${TMP}/etc/php/cipi-octane.d"
SUP_DIR="${TMP}/etc/supervisor/conf.d"
mkdir -p "$SUP_DIR"
{
    grep '^OCTANE_INI_DIR=' "${LIB}/common.sh"
    extract common.sh php_fpm_ini_hardening
    extract common.sh octane_php_ini_ensure
    extract common.sh _supervisor_remove_program
    extract common.sh _create_supervisor_octane
} | sed -e "s|/etc/php/cipi-octane.d|${INI_DIR}|g" \
        -e "s|/etc/supervisor/conf.d|${SUP_DIR}|g" > "${TMP}/gen-funcs.sh"
grep -q '^OCTANE_INI_DIR=' "${TMP}/gen-funcs.sh" && grep -q '^_create_supervisor_octane() {' "${TMP}/gen-funcs.sh" \
    && pass "generators extracted" || fail "could not extract the generators"

# ── octane_php_ini_ensure ────────────────────────────────────
(
    # shellcheck source=/dev/null
    source "${TMP}/gen-funcs.sh"
    octane_php_ini_ensure
) && pass "octane_php_ini_ensure returns 0" || fail "octane_php_ini_ensure failed"
INI="${INI_DIR}/99-cipi-hardening.ini"
grep -qx 'session.upload_progress.enabled = 0' "$INI" 2>/dev/null \
    && pass "ini turns session upload progress off" || fail "ini lacks session.upload_progress.enabled = 0"
grep -qx 'fatal_error_backtraces = 0' "$INI" 2>/dev/null \
    && pass "ini turns fatal error backtraces off" || fail "ini lacks fatal_error_backtraces = 0"
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
[[ "$(mode "$INI")" == "644" && "$(mode "$INI_DIR")" == "755" ]] \
    && pass "ini 0644 in a 0755 directory (readable by app users)" || fail "ini/dir mode: $(mode "$INI") $(mode "$INI_DIR")"
[[ -z "$(find "$INI_DIR" -name '.hardening.*')" ]] && pass "no temp file left behind" || fail "temp file left in ${INI_DIR}"
# The FPM pools and the Octane ini carry the same keys.
fpm_keys=$(extract common.sh fpm_pool_hardening | grep -oE 'php_admin_flag\[[a-z_.]+\]' | sed -E 's/php_admin_flag\[(.*)\]/\1/' | sort)
ini_keys=$(grep -E '^[a-z]' "$INI" | cut -d' ' -f1 | sort)
[[ -n "$fpm_keys" && "$fpm_keys" == "$ini_keys" ]] \
    && pass "Octane ini and fpm_pool_hardening set the same keys" || fail "keys differ: fpm=[${fpm_keys}] ini=[${ini_keys}]"

# ── _create_supervisor_octane ────────────────────────────────
(
    # shellcheck source=/dev/null
    source "${TMP}/gen-funcs.sh"
    _app_limit() { echo 4; }
    warn() { echo "WARN $*"; }
    rm -rf "${INI_DIR:?}"
    _create_supervisor_octane octo 8.4 8001
) > "${TMP}/gen.out" 2>&1
CONF="${SUP_DIR}/octo.conf"
grep -qx "environment=PHP_INI_SCAN_DIR=\":${INI_DIR}\"" "$CONF" \
    && pass "Octane program sets PHP_INI_SCAN_DIR with a leading ':'" || fail "no PHP_INI_SCAN_DIR line: $(cat "$CONF")"
[[ -f "$INI" ]] && pass "generator writes the ini when it is missing" || fail "generator did not write the ini"
grep -q 'octane:start --server=frankenphp --host=127.0.0.1 --port=8001 --workers=4' "$CONF" \
    && pass "command line unchanged" || fail "command line changed"
[[ $(grep -c '^environment=' "$CONF") -eq 1 ]] \
    && pass "exactly one environment= line" || fail "environment= count: $(grep -c '^environment=' "$CONF")"

# ── migration 5.7.1, end to end with stubs ───────────────────
STUB="${TMP}/lib"
mkdir -p "${STUB}/migrations"
SUPLOG="${TMP}/supervisorctl.log"
{
    cat "${TMP}/gen-funcs.sh"
    cat <<'EOF'
_app_limit() { echo 2; }
_supervisor_log_ready() { :; }   # 5.9.0: the log directory, not on this machine
warn() { echo "WARN $*"; }
id() { return 0; }
vault_read() { cat "${CIPI_CONFIG}/apps.json"; }
app_get() { vault_read apps.json | jq -r --arg a "$1" --arg k "$2" '.[$a][$k] // empty'; }
supervisorctl() {
    echo "$*" >> "$SUPLOG"
    case "$1" in
        reread) [[ "${REREAD_OK:-1}" == 1 ]] ;;
        status) [[ "$2" == stopped-octane ]] && echo "$2 STOPPED" || echo "$2 RUNNING"; return 0 ;;
        *) return 0 ;;
    esac
}
EOF
} > "${STUB}/common.sh"
sed -e "s|/etc/supervisor/conf.d|${SUP_DIR}|g" -e "s|/var/lib/cipi|${TMP}/var/lib/cipi|g" \
    "${LIB}/migrations/5.7.1.sh" > "${STUB}/migrations/5.7.1.sh"

old_program() {
    cat <<EOF
[program:$1-worker-default]
command=/usr/bin/php8.4 /home/$1/current/artisan queue:work
user=$1
[program:$1-octane]
process_name=%(program_name)s
command=/usr/bin/php8.4 /home/$1/current/artisan octane:start --server=frankenphp --host=127.0.0.1 --port=$2 --workers=2 --max-requests=500
autostart=true
user=$1
EOF
}

setup_server() {
    rm -rf "${SUP_DIR:?}" "${INI_DIR:?}" "${TMP:?}/var"
    mkdir -p "$SUP_DIR" "${TMP}/cfg"
    : > "$SUPLOG"
    cat > "${TMP}/cfg/apps.json" <<'EOF'
{"octo":{"php":"8.4","octane":"frankenphp","octane_port":"8001"},
 "stopped":{"php":"8.4","octane":"frankenphp","octane_port":"8002"},
 "fresh":{"php":"8.4","octane":"frankenphp","octane_port":"8003"},
 "plain":{"php":"8.4"}}
EOF
    old_program octo 8001 > "${SUP_DIR}/octo.conf"
    old_program stopped 8002 > "${SUP_DIR}/stopped.conf"
    printf '[program:plain-worker-default]\ncommand=true\n' > "${SUP_DIR}/plain.conf"
}

run_migration() {
    CIPI_LIB="$STUB" CIPI_CONFIG="${TMP}/cfg" SUPLOG="$SUPLOG" REREAD_OK="${1:-1}" \
        bash "${STUB}/migrations/5.7.1.sh" > "${TMP}/mig.out" 2>&1
}

setup_server
cp "${SUP_DIR}/plain.conf" "${TMP}/plain.before"
if run_migration; then pass "migration exits 0"; else fail "migration failed: $(cat "${TMP}/mig.out")"; fi
[[ -f "$INI" ]] && pass "migration writes the ini" || fail "migration did not write the ini"
for a in octo stopped; do
    grep -q '^environment=PHP_INI_SCAN_DIR=' "${SUP_DIR}/${a}.conf" \
        && pass "${a}: Octane program rewritten" || fail "${a}: not rewritten: $(cat "${SUP_DIR}/${a}.conf")"
    grep -qx "\[program:${a}-worker-default\]" "${SUP_DIR}/${a}.conf" \
        && pass "${a}: other programs kept" || fail "${a}: worker program lost"
    [[ $(grep -c "^\[program:${a}-octane\]" "${SUP_DIR}/${a}.conf") -eq 1 ]] \
        && pass "${a}: one Octane program" || fail "${a}: Octane program count wrong"
    [[ -f "${TMP}/var/lib/cipi/supervisor-backup-5.7.1/${a}.conf" ]] \
        && pass "${a}: previous file backed up" || fail "${a}: no backup"
done
cmp -s "${SUP_DIR}/plain.conf" "${TMP}/plain.before" && pass "FPM app untouched" || fail "FPM app changed"
[[ ! -e "${SUP_DIR}/fresh.conf" ]] && pass "Octane app without a program is left alone" || fail "program created for 'fresh'"
grep -qx 'update octo-octane' "$SUPLOG" && grep -qx 'update stopped-octane' "$SUPLOG" \
    && pass "rewritten programs are updated (restarted)" || fail "no update: $(cat "$SUPLOG")"
grep -qx 'stop stopped-octane' "$SUPLOG" && ! grep -qx 'stop octo-octane' "$SUPLOG" \
    && pass "a stopped program stays stopped, a running one keeps running" || fail "stop handling: $(cat "$SUPLOG")"

# second run: nothing to do, nothing restarted
cp "${SUP_DIR}/octo.conf" "${TMP}/octo.after1"
: > "$SUPLOG"
run_migration && cmp -s "${SUP_DIR}/octo.conf" "${TMP}/octo.after1" && ! grep -q '^update' "$SUPLOG" \
    && grep -q 'already hardened' "${TMP}/mig.out" \
    && pass "second run is a no-op" || fail "second run changed something: $(cat "${TMP}/mig.out") $(cat "$SUPLOG")"

# reread refused: old files back, nothing restarted
setup_server
cp "${SUP_DIR}/octo.conf" "${TMP}/octo.before"
run_migration 0 && cmp -s "${SUP_DIR}/octo.conf" "${TMP}/octo.before" && ! grep -q '^update' "$SUPLOG" \
    && grep -q 'restoring the previous programs' "${TMP}/mig.out" \
    && pass "refused reread restores the old programs and restarts nothing" || fail "rollback: $(cat "${TMP}/mig.out")"

# no Octane apps: exits before touching anything
setup_server
echo '{"plain":{"php":"8.4"}}' > "${TMP}/cfg/apps.json"
run_migration && [[ ! -e "$INI" ]] && [[ ! -s "$SUPLOG" ]] && grep -q 'no Octane apps' "${TMP}/mig.out" \
    && pass "server without Octane apps: nothing written" || fail "no-Octane path: $(cat "${TMP}/mig.out")"

# ── optional: a real FrankenPHP binary ───────────────────────
FPHP="${CIPI_TEST_FRANKENPHP:-}"
if [[ -n "$FPHP" && -x "$FPHP" ]]; then
    (source "${TMP}/gen-funcs.sh"; octane_php_ini_ensure)
    mkdir -p "${TMP}/www"
    cat > "${TMP}/www/index.php" <<'EOF'
<?php
ini_set('session.upload_progress.enabled', '1');
echo ini_get('session.upload_progress.enabled'), '|', ini_get('fatal_error_backtraces');
EOF
    port=$((20000 + RANDOM % 20000))
    (cd "$TMP" && PHP_INI_SCAN_DIR=":${INI_DIR}" exec "$FPHP" php-server --listen "127.0.0.1:${port}" --root www >/dev/null 2>&1) &
    fpid=$!
    body=""
    for _ in $(seq 1 50); do
        body=$(curl -fs "http://127.0.0.1:${port}/" 2>/dev/null) && break
        sleep 0.2
    done
    kill "$fpid" 2>/dev/null; wait "$fpid" 2>/dev/null
    [[ "$body" == "0|0" ]] && pass "FrankenPHP loads the ini; ini_set() cannot re-enable upload progress" \
        || fail "FrankenPHP answered '${body}', expected 0|0"
else
    echo "  SKIP: set CIPI_TEST_FRANKENPHP to a frankenphp binary to check a real one"
fi

echo
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
