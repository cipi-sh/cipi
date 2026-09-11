#!/usr/bin/env bash
# Local regression checks for 5.1.0.
# Run from repo root: bash tests/verify-5.1.0.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="${ROOT}/lib"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

pass() { echo "  OK: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if eval "$2" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi; }

echo "=== Cipi 5.1.0 regression checks ==="

# ── Release plumbing
[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.1.0" ]] && pass "version.md is 5.1.0" || fail "version.md"
[[ -f "${LIB}/migrations/5.1.0.sh" ]] && pass "migration 5.1.0 present" || fail "migration 5.1.0"
[[ -f "${LIB}/migrations/5.0.18.sh" ]] && pass "migration 5.0.18 still present" || fail "5.0.18 missing"
[[ ! -f "${LIB}/migrations/5.1.1.sh" ]] && pass "no stray 5.1.1 migration" || fail "stray 5.1.1"

echo "-- syntax"
for f in "${ROOT}/cipi" "${ROOT}/setup.sh" "${LIB}"/*.sh "${LIB}/migrations/5.1.0.sh"; do
    bash -n "$f" 2>/dev/null || fail "syntax: $f"
done
pass "all shell files parse"

# ── 1. Deploy failure notification (the bug: unreachable under set -e)
echo "-- deploy"
grep -q 'set +e' "${LIB}/deploy.sh" \
    && pass "_deploy_run disables set -e around the Deployer run" \
    || fail "deploy.sh still lets set -e abort before the failure branch"
grep -q 'rc=${PIPESTATUS\[0\]}' "${LIB}/deploy.sh" \
    && pass "deploy reads the real exit status from PIPESTATUS" \
    || fail "deploy exit status not captured"
grep -A4 'deploy_log_close "$app" "FAILED"' "${LIB}/deploy.sh" | grep -q 'error "Deploy failed' \
    && pass "failure branch is reachable" || fail "failure branch"
grep -q 'deploy_fail' "${LIB}/deploy.sh" && pass "deploy_fail notification present" || fail "deploy_fail"
grep -q 'deploy_log_tee' "${LIB}/deploy.sh" && pass "deploy output is timestamped" || fail "no timestamping"
grep -q 'deploy start' "${LIB}/deploy.sh" && pass "deploy log has a start banner" || fail "no start banner"
grep -q 'release=%s' "${LIB}/deploy.sh" && pass "deploy log records the release" || fail "no release in log"

# ── 2. Automatic (webhook) deploy path
echo "-- automatic deploy"
[[ -f "${LIB}/cipi-app-deploy.sh" ]] && pass "cipi-app-deploy.sh exists" || fail "cipi-app-deploy.sh missing"
grep -q 'cipi-app-deploy' "${LIB}/app.sh"  && pass "app.sh crontab uses the wrapper"  || fail "app.sh crontab"
grep -q 'cipi-app-deploy' "${LIB}/sync.sh" && pass "sync.sh crontab uses the wrapper" || fail "sync.sh crontab"
grep -q 'cipi-app-deploy' "${ROOT}/setup.sh" && pass "setup.sh installs the wrapper" || fail "setup.sh install"
grep -q 'cipi-app-deploy' "${LIB}/self-update.sh" && pass "self-update installs the wrapper" || fail "self-update install"
grep -q 'deploy-ok' "${LIB}/cipi-app-notify.sh" && pass "success notification supported" || fail "no deploy-ok"
grep -q 'deploy-ok' "${LIB}/cipi-app-deploy.sh" && pass "wrapper reports success too" || fail "wrapper success"

# ── 3. Horizon
echo "-- horizon"
grep -q 'reload_supervisor || reload_rc=$?' "${LIB}/worker.sh" \
    && pass "horizon enable survives a supervisor hiccup" || fail "horizon enable still fragile"
grep -A6 'reload_supervisor || reload_rc' "${LIB}/worker.sh" | grep -q 'app_set "$app" horizon "true"' \
    && pass "horizon state is written after the reload" || fail "horizon state write"
grep -q '_horizon_supervisor_state' "${LIB}/worker.sh" && pass "horizon status reads supervisor" || fail "horizon status"

# ── 4. Backup
echo "-- backup"
for fn in _bk_profile_add _bk_run_profile _bk_select_databases _bk_app_paths \
          _bk_prune_profile _bk_verify _bk_check_stale _bk_fetch _bk_encrypt_file; do
    grep -q "^${fn}()" "${LIB}/backup.sh" && pass "backup: ${fn}" || fail "backup: ${fn} missing"
done
grep -q 'htdocs' "${LIB}/backup.sh" && pass "custom apps (htdocs/) are archived" || fail "custom apps still skipped"
grep -q 'db_list_databases' "${LIB}/backup.sh" && pass "databases discovered from the engine" || fail "registry-only discovery"
grep -q 'databases/' "${LIB}/backup.sh" && pass "databases stored in their own directory" || fail "db/app not separated"
grep -q 'CIPI BACKUP START' "${LIB}/backup.sh" && pass "crontab block is marked" || fail "no crontab markers"
grep -q '_bk_prune_legacy' "${LIB}/backup.sh" && pass "legacy --weeks prune still works" || fail "legacy prune dropped"
grep -q 'db_dump_database_ex' "${LIB}/db.sh" && pass "dump supports table exclusions" || fail "no table exclusions"
grep -q 'db_list_databases' "${LIB}/db.sh" && pass "db.sh can enumerate live databases" || fail "db.sh discovery"

echo "-- backup integrity"
grep -q '_bk_check_archive' "${LIB}/backup.sh" && pass "archives are integrity-checked before storing" || fail "no integrity check"
grep -q 'tar_rc -ge 2' "${LIB}/backup.sh" && pass "tar warnings are not treated as failures" || fail "tar exit 1 still fails the backup"
grep -q 'if . == null then empty else tostring end' "${LIB}/backup.sh" \
    && pass "profile booleans read correctly (jq // false pitfall)" || fail "jq // false pitfall present"
grep -q 'created_at' "${LIB}/backup.sh" && pass "new profiles are not reported overdue" || fail "no created_at"
grep -q 'nothing was downloaded' "${LIB}/backup.sh" && pass "fetch refuses to claim an empty download" || fail "fetch can report a false success"

cat > "${TMP}/arch.sh" <<'AR'
set -uo pipefail
RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
CIPI_CONFIG=/tmp/cipi-t; CIPI_LOG=/tmp/cipi-t; CIPI_LIB=LIBDIR
info(){ :; }; warn(){ :; }; error(){ :; }; success(){ :; }; step(){ :; }
vault_read(){ echo '{}'; }; vault_write(){ cat >/dev/null; }
source LIBDIR/backup.sh
D=TMPDIR/arch; rm -rf "$D"; mkdir -p "$D"
echo hello > "$D/f"; tar -czf "$D/good.tar.gz" -C "$D" f 2>/dev/null
_bk_check_archive "$D/good.tar.gz" || exit 60
head -c 40 "$D/good.tar.gz" > "$D/trunc.tar.gz"
_bk_check_archive "$D/trunc.tar.gz" && exit 61
: > "$D/empty.sql.gz"
_bk_check_archive "$D/empty.sql.gz" && exit 62
exit 0
AR
sed -i.bak "s#LIBDIR#${LIB}#g; s#TMPDIR#${TMP}#g" "${TMP}/arch.sh" && rm -f "${TMP}/arch.sh.bak"
if bash "${TMP}/arch.sh"; then pass "good archive accepted, truncated and empty rejected"
else fail "archive integrity check (exit $?)"; fi

echo "-- backup helper behaviour"
cat > "${TMP}/bk.sh" <<'BK'
set -uo pipefail
RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
CIPI_CONFIG=/tmp/cipi-t; CIPI_LOG=/tmp/cipi-t; CIPI_LIB=LIBDIR
info(){ :; }; warn(){ :; }; error(){ :; }; success(){ :; }; step(){ :; }
vault_read(){ echo '{}'; }; vault_write(){ cat >/dev/null; }
source LIBDIR/backup.sh
_bk_valid_cron "0 2 * * *"        || exit 10
_bk_valid_cron "0 2 * * * ; evil" && exit 11
_bk_valid_cron "0 2 * *"          && exit 12
[[ "$(_bk_every_to_cron 30m)" == "1800	*/30 * * * *" ]] || exit 13
[[ "$(_bk_every_to_cron 6h)"  == "21600	0 */6 * * *" ]]  || exit 14
_bk_every_to_cron 7m  && exit 15
_bk_every_to_cron bad && exit 16
[[ "$(_bk_cron_interval_seconds '*/15 * * * *')" == "900" ]] || exit 17
_bk_glob_match tenant_7 "$(printf 'tenant_*')" || exit 18
_bk_glob_match main     "$(printf 'tenant_*')" && exit 19
_bk_glob_match x        ""                     && exit 20
_bk_valid_profile_name hourly-db || exit 21
_bk_valid_profile_name 'x;rm'    && exit 22
[[ "$(_bk_csv_to_json 'a, b ,c' | jq -c .)" == '["a","b","c"]' ]] || exit 23
# a false boolean must read as "false", not as an empty string
_bk_profiles_json(){ echo '{"p1":{"enabled":false,"encrypt":false,"scope":"db"}}'; }
[[ "$(_bk_profile_get p1 enabled)" == "false" ]] || exit 24
[[ "$(_bk_profile_get p1 encrypt)" == "false" ]] || exit 25
[[ "$(_bk_profile_get p1 scope)"   == "db" ]]    || exit 26
[[ -z "$(_bk_profile_get p1 missing)" ]]         || exit 27
exit 0
BK
sed -i.bak "s#LIBDIR#${LIB}#g" "${TMP}/bk.sh" && rm -f "${TMP}/bk.sh.bak"
if bash "${TMP}/bk.sh"; then pass "backup helpers behave (cron, intervals, globs, names)"
else fail "backup helpers (exit $?)"; fi

# ── 5. php.ini
echo "-- ini"
[[ -f "${LIB}/ini.sh" ]] && pass "ini.sh exists" || fail "ini.sh missing"
grep -q 'ini_command' "${ROOT}/cipi" && pass "cipi ini is wired up" || fail "cipi ini not dispatched"
grep -q 'cli/conf.d' "${LIB}/ini.sh" && pass "server-wide set also writes the CLI SAPI" || fail "CLI SAPI not written"
grep -q 'auto_prepend_file' "${LIB}/ini.sh" && pass "dangerous keys are explicitly refused" || fail "no deny list"
grep -q '_ini_cascade' "${LIB}/ini.sh" && pass "companion limits are raised with the change" || fail "no cascade"
grep -q 'client_max_body_size' "${LIB}/ini.sh" && pass "nginx body cap is surfaced" || fail "no nginx warning"
grep -q 'php_admin_value\[upload_max_filesize\]' "${LIB}/app.sh" \
    && fail "FPM pool still hardcodes upload_max_filesize (shadows the global file)" \
    || pass "FPM pool no longer shadows the server-wide php.ini"
grep -q '.ini // {}) | to_entries' "${LIB}/app.sh" && pass "FPM pool renders per-app overrides" || fail "pool overrides"
grep -q 'cli/conf.d/99-cipi.ini' "${LIB}/migrations/5.1.0.sh" && pass "migration adds the CLI ini" || fail "migration CLI ini"

# ── 6. cipi.yml
echo "-- cipi.yml"
[[ -f "${LIB}/yml.sh" ]] && pass "yml.sh exists" || fail "yml.sh missing"
grep -q 'yml_command' "${ROOT}/cipi" && pass "cipi yml is wired up" || fail "cipi yml not dispatched"

cat > "${TMP}/yml.sh" <<'YS'
set -uo pipefail
RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
CIPI_LIB=LIBDIR; CIPI_CONFIG=/tmp/cipi-t; CIPI_LOG=/tmp/cipi-t
info(){ :; }; warn(){ :; }; error(){ :; }; success(){ :; }; step(){ :; }
source LIBDIR/yml.sh
ok(){ [[ "$(_yml_parse "$1" "$2" | jq -r .ok)" == "true" ]]; }
_yml_example > TMPDIR/example.yml
ok TMPDIR/example.yml example || exit 30

w(){ printf '%s\n' "$2" > TMPDIR/c.yml; if ok TMPDIR/c.yml iceberg; then echo "ACCEPTED: $1"; exit 31; fi; }
w "cross-app database"   'version: 1
databases:
  - name: otherapp'
w "cross-app backup profile" 'version: 1
backup:
  profiles:
    - name: default
      keep: 5'
w "auto_prepend_file"    'version: 1
app:
  ini:
    auto_prepend_file: /tmp/x.php'
w "cron injection"       'version: 1
backup:
  profiles:
    - name: iceberg-x
      cron: "0 2 * * * ; curl x|bash"
      keep: 3'
w "yaml anchor"          'version: 1
a: &x
  b: 1'
w "no retention"         'version: 1
backup:
  profiles:
    - name: iceberg-x
      every: 30m'
w "unknown top-level key" 'version: 1
bogus: 1'
w "missing version"      'app:
  php: "8.5"'
w "unsupported php"      'version: 1
app:
  php: "8.2"'
w "sql metachars in db"  'version: 1
databases:
  - name: "iceberg_x; DROP DATABASE main"'
w "horizon and queues"   'version: 1
workers:
  horizon: true
  queues:
    - default'
exit 0
YS
sed -i.bak "s#LIBDIR#${LIB}#g; s#TMPDIR#${TMP}#g" "${TMP}/yml.sh" && rm -f "${TMP}/yml.sh.bak"
out=$(bash "${TMP}/yml.sh" 2>&1); rc=$?
if [[ $rc -eq 0 ]]; then pass "cipi.yml: template valid, 11 hostile documents rejected"
else fail "cipi.yml validation (${out})"; fi

# cipi.yml: healthcheck section
cat > "${TMP}/hy.sh" <<'HY'
set -uo pipefail
RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
CIPI_LIB=LIBDIR; CIPI_CONFIG=/tmp/cipi-t; CIPI_LOG=/tmp/cipi-t
info(){ :; }; warn(){ :; }; error(){ :; }; success(){ :; }; step(){ :; }
APPS='{"iceberg":{"domain":"icebergpro.it","aliases":["*.icebergpro.it","www.icebergpro.it"]}}'
app_get(){ echo "$APPS" | jq -r --arg a "$1" --arg k "$2" '.[$a][$k] // empty'; }
vault_read(){ echo "$APPS"; }
source LIBDIR/yml.sh
ok(){ printf '%s
' "$1" > TMPDIR/hy.yml; [[ "$(_yml_parse TMPDIR/hy.yml iceberg | jq -r .ok)" == "true" ]]; }
ok 'version: 1
health:
  url: "https://icebergpro.it/up"
  expect: 200' || exit 70
ok 'version: 1
health:
  enabled: false' || exit 71
ok 'version: 1
health:
  url: "https://user:pw@evil.com/x"' && exit 72
ok 'version: 1
health:
  url: "https://icebergpro.it/up?a=1"' && exit 73
ok 'version: 1
health:
  url: "file:///etc/passwd"' && exit 74
ok 'version: 1
health:
  url: "https://icebergpro.it/up"
  expect: 99' && exit 75
ok 'version: 1
health:
  url: "https://icebergpro.it/up"
  grace: 999' && exit 76
ok 'version: 1
health:
  url: "https://icebergpro.it/up"
  timeout: 5' && exit 77
ok 'version: 1
health:
  enabled: false
  url: "https://icebergpro.it/up"' && exit 78
ok 'version: 1
health:
  expect: 200' && exit 79
# the URL must belong to the app
_yml_url_belongs_to_app iceberg "https://icebergpro.it/up"        || exit 80
_yml_url_belongs_to_app iceberg "https://www.icebergpro.it/up"    || exit 81
_yml_url_belongs_to_app iceberg "https://t7.icebergpro.it/up"     || exit 82
_yml_url_belongs_to_app iceberg "http://127.0.0.1:8080/admin"     && exit 83
_yml_url_belongs_to_app iceberg "https://169.254.169.254/latest/" && exit 84
_yml_url_belongs_to_app iceberg "https://altrocliente.it/up"      && exit 85
_yml_url_belongs_to_app iceberg "https://icebergpro.it.evil.com/" && exit 86
exit 0
HY
sed -i.bak "s#LIBDIR#${LIB}#g; s#TMPDIR#${TMP}#g" "${TMP}/hy.sh" && rm -f "${TMP}/hy.sh.bak"
hout=$(bash "${TMP}/hy.sh" 2>&1); hrc=$?
[[ $hrc -eq 0 ]] && pass "cipi.yml health: valid forms accepted, 8 bad ones rejected, URL confined to the app's domains" \
                 || fail "cipi.yml health section (exit ${hrc}: ${hout})"
grep -q 'aim the server' "${LIB}/yml.sh" && pass "the URL restriction explains itself" || fail "no SSRF guard message"
grep -q 'health-unset' "${LIB}/yml.sh" && pass "cipi.yml can remove a healthcheck" || fail "no health removal"
grep -q 'rollback_on_unhealthy' "${LIB}/yml.sh" && pass "cipi.yml can declare auto-rollback" || fail "no rollback in yml"

grep -q 'a project file cannot' "${LIB}/yml.sh" && pass "namespacing is enforced with an explanation" || fail "namespacing"

# generate must produce something this same Cipi accepts, and round-trip exactly
cat > "${TMP}/gen.sh" <<'GS'
set -uo pipefail
RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
CIPI_LIB=LIBDIR; CIPI_CONFIG=/tmp/cipi-t; CIPI_LOG=/tmp/cipi-t
info(){ :; }; warn(){ echo "WARN $*" >&2; }; error(){ echo "ERR $*" >&2; }
success(){ :; }; step(){ :; }
APPS='{"iceberg":{"domain":"icebergpro.it","aliases":["*.icebergpro.it","www.icebergpro.it"],
 "php":"8.5","custom":false,"horizon":false,
 "ini":{"upload_max_filesize":"50M","display_errors":"Off"}}}'
BK='{"bucket":"b","profiles":{
 "default":{"scope":"all","cron":"0 2 * * *","destinations":["s3"],"retention":{"keep":0,"days":28,"weeks":0},"encrypt":false,"enabled":true},
 "iceberg-db":{"scope":"db","databases":["iceberg","tenant_*"],"exclude_tables":["*.jobs"],
   "cron":"*/30 * * * *","destinations":["local"],"retention":{"keep":48,"days":0,"weeks":0},"encrypt":false,"enabled":true}}}'
vault_read(){ case "$1" in apps.json) echo "$APPS";; backup.json) echo "$BK";; *) echo '{}';; esac; }
vault_write(){ cat >/dev/null; }
app_exists(){ [[ "$1" == iceberg ]]; }
app_get(){ echo "$APPS" | jq -r --arg a "$1" --arg k "$2" '.[$a][$k] // empty'; }
db_engine_is_installed(){ [[ "$1" == mariadb ]]; }
db_list_databases(){ [[ "$1" == mariadb ]] && printf 'iceberg\niceberg_reporting\ntenant_1\nsomeoneelse\n'; }
crontab(){ printf '* * * * * /usr/bin/php8.5 /home/iceberg/current/artisan schedule:run\n'; }
hostname(){ echo vps-test; }
source LIBDIR/backup.sh
source LIBDIR/yml.sh
_yml_source_libs(){ :; }
_bk_configured(){ return 0; }
_yml_read_workers(){ printf 'default\t3\t3\t3600\nemails\t1\t5\t300\n'; }
_yml_generate iceberg > TMPDIR/gen.yml 2>TMPDIR/gen.err
[[ -s TMPDIR/gen.err ]] && { cat TMPDIR/gen.err >&2; exit 40; }
[[ "$(_yml_parse TMPDIR/gen.yml iceberg | jq -r .ok)" == "true" ]] || exit 41
d=$(_yml_parse TMPDIR/gen.yml iceberg | jq -c .data)
[[ "$(echo "$d" | jq -r '.app.php')" == "8.5" ]] || exit 42
[[ "$(echo "$d" | jq -c '.app.aliases')" == '["*.icebergpro.it","www.icebergpro.it"]' ]] || exit 43
[[ "$(echo "$d" | jq -r '.app.ini["display_errors"]')" == "Off" ]] || exit 44
[[ "$(echo "$d" | jq -c '[.databases[].name]')" == '["iceberg_reporting"]' ]] || exit 45
[[ "$(echo "$d" | jq -c '[.workers.queues[] | [.queue,.processes,.tries,.timeout]]')" \
   == '[["default",3,3,3600],["emails",1,5,300]]' ]] || exit 46
[[ "$(echo "$d" | jq -r '.schedule')" == "true" ]] || exit 47
[[ "$(echo "$d" | jq -c '[.backup.profiles[].name]')" == '["iceberg-db"]' ]] || exit 48
[[ "$(echo "$d" | jq -r '.backup.profiles[0].every')" == "30m" ]] || exit 49
[[ "$(echo "$d" | jq -r '.backup.profiles[0].retention.keep')" == "48" ]] || exit 50
exit 0
GS
sed -i.bak "s#LIBDIR#${LIB}#g; s#TMPDIR#${TMP}#g" "${TMP}/gen.sh" && rm -f "${TMP}/gen.sh.bak"
gout=$(bash "${TMP}/gen.sh" 2>&1); grc=$?
if [[ $grc -eq 0 ]]; then pass "cipi yml generate round-trips through the validator unchanged"
else fail "cipi yml generate (exit ${grc}: ${gout})"; fi
grep -q "'default' stay out of the repository" "${LIB}/yml.sh" \
    && pass "generate leaves server-wide backup profiles out" || fail "generate namespacing"
grep -q '_yml_cron_to_every' "${LIB}/yml.sh" && pass "generate renders cron back as every:" || fail "no every: rendering"
grep -q 'sudoers.d/cipi-\${app}-yml' "${LIB}/yml.sh" && pass "auto-apply uses a scoped sudoers rule" || fail "auto-apply sudoers"
grep -q 'yml_auto' "${LIB}/yml.sh" && pass "auto-apply is opt-in per app" || fail "auto-apply gate"

# both deploy paths must honour the same opt-in
grep -q '_deploy_apply_yml' "${LIB}/deploy.sh" \
    && pass "cipi deploy applies cipi.yml when opted in" || fail "CLI deploy ignores cipi.yml"
grep -q 'cipi yml apply' "${LIB}/cipi-app-deploy.sh" \
    && pass "webhook deploy applies cipi.yml when opted in" || fail "webhook deploy ignores cipi.yml"
grep -A3 '_deploy_apply_yml() {' "${LIB}/deploy.sh" | grep -q 'yml_auto.*== "true".*|| return 0' \
    && pass "deploy hook is gated on the opt-in" || fail "deploy hook not gated"

cat > "${TMP}/auto.sh" <<'AS'
set -uo pipefail
RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
CIPI_LIB=LIBDIR; CIPI_CONFIG=/tmp/cipi-t; CIPI_LOG=/tmp/cipi-t
info(){ echo "INFO $*"; }; warn(){ :; }; error(){ echo "ERR $*"; }
success(){ :; }; step(){ :; }
parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --*=*) local k="${arg%%=*}" v="${arg#*=}"; k="${k#--}"; printf -v "ARG_${k//-/_}" '%s' "$v" ;;
            --*)   local k="${arg#--}"; printf -v "ARG_${k//-/_}" '%s' "true" ;;
        esac
    done
}
YMLAUTO="$1"
app_exists(){ [[ "$1" == iceberg ]]; }
app_get(){ [[ "$2" == yml_auto ]] && echo "$YMLAUTO"; }
source LIBDIR/yml.sh
_yml_find_file(){ [[ -f TMPDIR/cipi.yml ]] && { echo TMPDIR/cipi.yml; return 0; }; return 1; }
_yml_source_libs(){ :; }
_yml_build_plan(){ _YML_ACTIONS=(); _YML_BLOCKERS=(); }
_yml_apply_cmd iceberg --yes --auto
AS
sed -i.bak "s#LIBDIR#${LIB}#g; s#TMPDIR#${TMP}#g" "${TMP}/auto.sh" && rm -f "${TMP}/auto.sh.bak"

rm -f "${TMP}/cipi.yml"
o=$(bash "${TMP}/auto.sh" true 2>&1); r=$?
[[ $r -eq 0 && "$o" == *"nothing to reconcile"* ]] \
    && pass "auto: a release with no cipi.yml is a quiet no-op" \
    || fail "auto: missing file should not error (exit ${r}: ${o})"

o=$(bash "${TMP}/auto.sh" false 2>&1); r=$?
[[ $r -ne 0 && "$o" == *"not enabled"* ]] \
    && pass "auto: --auto is refused when the app has not opted in" \
    || fail "auto: --auto not gated (exit ${r}: ${o})"

printf 'version: 1\napp:\n  php: "8.5"\n' > "${TMP}/cipi.yml"
o=$(bash "${TMP}/auto.sh" true 2>&1); r=$?
[[ $r -eq 0 ]] && pass "auto: a valid file applies cleanly" || fail "auto: valid file (exit ${r}: ${o})"

printf 'version: 1\ndatabases:\n  - name: otherapp\n' > "${TMP}/cipi.yml"
o=$(bash "${TMP}/auto.sh" true 2>&1); r=$?
[[ $r -ne 0 && "$o" == *"namespace"* ]] \
    && pass "auto: an out-of-namespace file is refused, not applied" \
    || fail "auto: hostile file (exit ${r}: ${o})"
rm -f "${TMP}/cipi.yml"

# ── 6b. Post-deploy healthcheck
echo "-- post-deploy healthcheck"
grep -q '^health_post_deploy()' "${LIB}/health.sh" && pass "health_post_deploy exists" || fail "health_post_deploy missing"
grep -q '_deploy_health_check' "${LIB}/deploy.sh" && pass "cipi deploy verifies the release" || fail "CLI deploy has no health step"
grep -q 'cipi health postdeploy' "${LIB}/cipi-app-deploy.sh" && pass "webhook deploy verifies the release" || fail "webhook has no health step"
grep -q 'cipi health postdeploy \${app_user}' "${LIB}/app.sh" && pass "sudoers allows it from the app user" || fail "sudoers rule missing"
grep -q 'cipi health postdeploy' "${LIB}/migrations/5.1.0.sh" && pass "migration backfills the sudoers rule" || fail "migration sudoers"
grep -q '^deploy_health_fail|' "${LIB}/notifications.sh" && pass "trigger deploy_health_fail" || fail "trigger missing"
grep -q 'echo "000")' "${LIB}/health.sh" && fail "health.sh still double-appends 000 on connection failure" \
    || pass "connection failures report a single 000"
grep -q 'echo "000")' "${LIB}/cipi-health-check.sh" && fail "cron helper still double-appends 000" \
    || pass "cron helper reports a single 000"

# behaviour against a real HTTP server
cat > "${TMP}/hsrv.py" <<'PYS'
import http.server, sys
n = [0]
FLIP = int(sys.argv[2]); CODE = int(sys.argv[3])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        n[0] += 1
        self.send_response(200 if n[0] > FLIP else CODE)
        self.end_headers(); self.wfile.write(b"x")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYS
cat > "${TMP}/h.sh" <<'HS'
set -uo pipefail
RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
CIPI_LIB=LIBDIR; CIPI_CONFIG=/tmp/cipi-t; CIPI_LOG=TMPDIR/hlog
export HEALTH_PD_DELAY=1
mkdir -p "$CIPI_LOG"
info(){ :; }; warn(){ :; }; error(){ :; }; success(){ :; }; step(){ :; }
log_action(){ :; }
cipi_notify(){ echo "NOTIFY:$3"; }
APP_JSON="$1"
app_get(){ echo "$APP_JSON" | jq -r --arg k "$2" '.[$k] // empty'; }
app_exists(){ return 0; }
source LIBDIR/health.sh
health_post_deploy iceberg deploy
HS
sed -i.bak "s#LIBDIR#${LIB}#g; s#TMPDIR#${TMP}#g" "${TMP}/h.sh" && rm -f "${TMP}/h.sh.bak"

if command -v python3 >/dev/null 2>&1; then
    HP=8791
    python3 "${TMP}/hsrv.py" "$HP" 0 200 >/dev/null 2>&1 &
    HSRV=$!; sleep 1
    o=$(bash "${TMP}/h.sh" "{\"health_url\":\"http://127.0.0.1:${HP}/up\",\"health_expect\":\"200\",\"health_grace\":\"0\"}" 2>&1); r=$?
    [[ $r -eq 0 && "$o" != *NOTIFY* ]] && pass "healthy release: passes, no alert" || fail "healthy release (rc=$r: $o)"
    kill $HSRV 2>/dev/null; wait $HSRV 2>/dev/null

    HP=8792
    python3 "${TMP}/hsrv.py" "$HP" 2 502 >/dev/null 2>&1 &
    HSRV=$!; sleep 1
    o=$(bash "${TMP}/h.sh" "{\"health_url\":\"http://127.0.0.1:${HP}/up\",\"health_expect\":\"200\",\"health_grace\":\"0\"}" 2>&1); r=$?
    [[ $r -eq 0 && "$o" != *NOTIFY* ]] && pass "slow-starting app: retries then passes" || fail "retry path (rc=$r: $o)"
    kill $HSRV 2>/dev/null; wait $HSRV 2>/dev/null

    HP=8793
    python3 "${TMP}/hsrv.py" "$HP" 99 500 >/dev/null 2>&1 &
    HSRV=$!; sleep 1
    o=$(bash "${TMP}/h.sh" "{\"health_url\":\"http://127.0.0.1:${HP}/up\",\"health_expect\":\"200\",\"health_grace\":\"0\"}" 2>&1); r=$?
    [[ $r -eq 1 && "$o" == *"NOTIFY:deploy_health_fail"* ]] \
        && pass "broken release: fails and alerts immediately" || fail "broken release (rc=$r: $o)"
    kill $HSRV 2>/dev/null; wait $HSRV 2>/dev/null

    o=$(bash "${TMP}/h.sh" '{"health_url":"http://127.0.0.1:9/up","health_expect":"200","health_grace":"0"}' 2>&1); r=$?
    [[ $r -eq 1 && "$o" == *"NOTIFY:deploy_health_fail"* ]] \
        && pass "unreachable app: fails and alerts" || fail "unreachable (rc=$r: $o)"

    for spec in '{}' '{"health_url":"http://127.0.0.1:9/","health_postdeploy":"false"}' '{"health_url":"http://127.0.0.1:9/","suspended":"true"}'; do
        o=$(bash "${TMP}/h.sh" "$spec" 2>&1); r=$?
        [[ $r -eq 2 && "$o" != *NOTIFY* ]] || fail "skip case not honoured: ${spec} (rc=$r)"
    done
    pass "skipped cleanly: unset, opted out, suspended"
else
    echo "  SKIP: python3 unavailable, health behaviour not exercised"
fi

# ── 6c. Auto-rollback on an unhealthy release
echo "-- auto-rollback"
grep -q '^_deploy_auto_rollback()' "${LIB}/deploy.sh" && pass "_deploy_auto_rollback exists" || fail "missing"
grep -q 'health_rollback' "${LIB}/health.sh" && pass "policy stored per app" || fail "no health_rollback setting"
grep -q 'ARG_rollback_on_unhealthy' "${LIB}/deploy.sh" && pass "--rollback-on-unhealthy honoured" || fail "flag missing"
grep -q 'migrations are NOT undone' "${LIB}/deploy.sh" && pass "migration caveat stated in the alert" || fail "no migration caveat"
grep -q 'cipi health postdeploy \${app_user} --auto' "${LIB}/app.sh" \
    && pass "manual postdeploy cannot trigger a rollback (sudoers uses --auto)" || fail "sudoers not scoped to --auto"

cat > "${TMP}/rb.sh" <<'RS'
set -uo pipefail
RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
CIPI_LIB=LIBDIR; CIPI_CONFIG=/tmp/cipi-t; CIPI_LOG=TMPDIR/rblog
export HEALTH_PD_DELAY=1
mkdir -p "$CIPI_LOG"
info(){ :; }; warn(){ :; }; error(){ :; }; success(){ :; }; step(){ :; }
log_action(){ :; }
cipi_notify(){ echo "SUBJECT:$1"; }
APP_JSON="$1"; ROLLBACK_RC="$2"; NRELEASES="$3"
app_get(){ echo "$APP_JSON" | jq -r --arg k "$2" '.[$k] // empty'; }
app_exists(){ return 0; }
HOME_FAKE=TMPDIR/rbhome
rm -rf "$HOME_FAKE"; mkdir -p "$HOME_FAKE/releases" "$HOME_FAKE/logs"
for i in $(seq 1 "$NRELEASES"); do mkdir -p "$HOME_FAKE/releases/$i"; done
ln -sfn "releases/${NRELEASES}" "$HOME_FAKE/current"
source LIBDIR/deploy.sh
source LIBDIR/health.sh
deploy_app_home(){ echo "$HOME_FAKE"; }
_deploy_commit_info(){ echo "a1b2c3d|Fix checkout|Jane Doe|2026-09-02 15:40"; }
sudo(){
  [[ "$ROLLBACK_RC" != "0" ]] && { echo "dep: rollback failed"; return "$ROLLBACK_RC"; }
  local cur prev
  cur=$(basename "$(readlink "$HOME_FAKE/current")")
  prev=$(( cur - 1 )); [[ $prev -lt 1 ]] && prev=1
  ln -sfn "releases/${prev}" "$HOME_FAKE/current"; return 0
}
deploy_post_release_verify iceberg deploy
echo "RC:$?"
echo "SUMMARY:$DEPLOY_VERIFY_SUMMARY"
echo "RELEASE:$(deploy_current_release iceberg)"
RS
sed -i.bak "s#LIBDIR#${LIB}#g; s#TMPDIR#${TMP}#g" "${TMP}/rb.sh" && rm -f "${TMP}/rb.sh.bak"

if command -v python3 >/dev/null 2>&1; then
    RP=8811
    python3 "${TMP}/hsrv.py" "$RP" 5 502 >/dev/null 2>&1 &   # 5 failures, then healthy
    RSRV=$!; sleep 1
    A="{\"health_url\":\"http://127.0.0.1:${RP}/up\",\"health_expect\":\"200\",\"health_grace\":\"0\",\"health_rollback\":\"true\",\"php\":\"8.5\",\"branch\":\"main\"}"
    o=$(bash "${TMP}/rb.sh" "$A" 0 3 2>&1)
    [[ "$o" == *"healthy again"* && "$o" == *"RELEASE:2"* && "$o" == *"RC:1"* ]] \
        && pass "unhealthy release is rolled back and the app recovers" \
        || fail "rollback recovery (${o})"
    kill $RSRV 2>/dev/null; wait $RSRV 2>/dev/null

    RP=8812
    python3 "${TMP}/hsrv.py" "$RP" 99 500 >/dev/null 2>&1 &  # never healthy
    RSRV=$!; sleep 1
    A="{\"health_url\":\"http://127.0.0.1:${RP}/up\",\"health_expect\":\"200\",\"health_grace\":\"0\",\"health_rollback\":\"true\",\"php\":\"8.5\",\"branch\":\"main\"}"
    o=$(bash "${TMP}/rb.sh" "$A" 0 3 2>&1)
    [[ "$o" == *"STILL unhealthy"* ]] \
        && pass "rollback that does not help says so (look past the code)" || fail "still-unhealthy path (${o})"

    o=$(bash "${TMP}/rb.sh" "$A" 1 3 2>&1)
    [[ "$o" == *"ROLLBACK FAILED"* ]] \
        && pass "a failed rollback is reported as still live" || fail "rollback-failed path (${o})"

    o=$(bash "${TMP}/rb.sh" "$A" 0 1 2>&1)
    [[ "$o" == *"no rollback possible"* && "$o" == *"RELEASE:1"* ]] \
        && pass "with a single release nothing is moved" || fail "single-release guard (${o})"

    A="{\"health_url\":\"http://127.0.0.1:${RP}/up\",\"health_expect\":\"200\",\"health_grace\":\"0\",\"php\":\"8.5\"}"
    o=$(bash "${TMP}/rb.sh" "$A" 0 3 2>&1)
    [[ "$o" == *"RELEASE:3"* && "$o" != *"rolled back"* ]] \
        && pass "without the opt-in an unhealthy release is left alone" || fail "opt-out (${o})"
    kill $RSRV 2>/dev/null; wait $RSRV 2>/dev/null
fi

# ── 6d. Deploy notifications carry the release and the commit
echo "-- deploy notifications"
grep -q '_deploy_release_details' "${LIB}/deploy.sh" && pass "shared release detail builder" || fail "no detail builder"
grep -q "Commit: %s — %s" "${LIB}/deploy.sh" && pass "success/failure mail names the commit" || fail "no commit in mail"
grep -q 'deploy succeeded: \${app} release' "${LIB}/deploy.sh" && pass "success subject carries the release" || fail "success subject"
grep -q 'deploy FAILED: \${app}' "${LIB}/deploy.sh" && pass "failure subject is visibly different" || fail "failure subject"
grep -q 'Healthcheck: \${health_line}' "${LIB}/deploy.sh" && pass "success mail states the health verdict" || fail "no health verdict in mail"
grep -q 'Commit: ' "${LIB}/cipi-app-deploy.sh" && pass "webhook mail names the commit too" || fail "webhook commit"
awk '/cipi health postdeploy/{h=NR} /deploy-ok/{d=NR} END{exit !(h && d && h < d)}' "${LIB}/cipi-app-deploy.sh" \
    && pass "webhook success mail is sent after the healthcheck" || fail "webhook mail ordering"

# ── 6e. The migration must never abort (it would pin the server on the old version)
echo "-- migration robustness"
grep -q 'head -1 || true' "${LIB}/migrations/5.1.0.sh" \
    && pass "the weeks lookup cannot abort the migration" || fail "pipefail abort still possible"
grep -c 'WARNING:' "${LIB}/migrations/5.1.0.sh" >/dev/null \
    && [[ $(grep -c 'WARNING:' "${LIB}/migrations/5.1.0.sh") -ge 5 ]] \
    && pass "each step degrades to a warning" || fail "steps can still be fatal"

MIG="${TMP}/mig"; rm -rf "$MIG"; mkdir -p "$MIG"/{etc,log,bin,lib}
cp "${LIB}"/*.sh "$MIG/lib/" 2>/dev/null; cp -r "${LIB}/migrations" "$MIG/lib/"
for c in crontab systemctl visudo chown id; do printf '#!/bin/bash\nexit 0\n' > "$MIG/bin/$c"; chmod +x "$MIG/bin/$c"; done
printf '#!/bin/bash\nexit 1\n' > "$MIG/bin/nginx"; chmod +x "$MIG/bin/nginx"
# crontab with no legacy prune line — the exact case that used to abort
printf '#!/bin/bash\n[[ "$1" == "-l" ]] && { echo "0 4 * * * /usr/local/bin/other"; exit 0; }\ncat >/dev/null 2>&1\nexit 0\n' > "$MIG/bin/crontab"
chmod +x "$MIG/bin/crontab"

mrc=0
( export PATH="$MIG/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  CIPI_LIB="$MIG/lib" CIPI_CONFIG="$MIG/etc" CIPI_LOG="$MIG/log" \
  bash "$MIG/lib/migrations/5.1.0.sh" >/dev/null 2>&1 ) || mrc=$?
[[ $mrc -eq 0 ]] && pass "migration completes on a bare server (no apps, no backup config)" \
                 || fail "migration aborted (exit ${mrc})"

# now with a backup config present but no legacy cron line
( CIPI_CONFIG="$MIG/etc"; source "${LIB}/vault.sh"
  echo '{"bucket":"b","region":"eu-central-1","profiles":{}}' | vault_write backup.json ) 2>/dev/null
mrc=0
( export PATH="$MIG/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  CIPI_LIB="$MIG/lib" CIPI_CONFIG="$MIG/etc" CIPI_LOG="$MIG/log" \
  bash "$MIG/lib/migrations/5.1.0.sh" >"$MIG/out.txt" 2>&1 ) || mrc=$?
[[ $mrc -eq 0 ]] && pass "migration completes with a backup config and no legacy cron line" \
                 || fail "migration aborted on the legacy-cron path (exit ${mrc})"
grep -q "converted to profile 'default'" "$MIG/out.txt" \
    && pass "the old nightly job is converted into a profile" || fail "no profile conversion"
grep -q "kept 4 weeks" "$MIG/out.txt" \
    && pass "retention falls back to the previous 4 weeks" || fail "retention default"

grep -q 'return 2' "${LIB}/nginx.sh" \
    && pass "nginx distinguishes 'nothing to claim' from 'cannot write'" || fail "nginx status conflated"

# ── 7. nginx default server
echo "-- nginx"
grep -q 'nginx_default_server_owner' "${LIB}/nginx.sh" && pass "default_server detected per port" || fail "per-port detection"
grep -q 'ssl_reject_handshake' "${LIB}/nginx.sh" && pass "HTTPS catch-all rejects the handshake" || fail "no ssl catch-all"
grep -q '000-cipi-default' "${ROOT}/setup.sh" && pass "fresh installs get the HTTPS catch-all" || fail "setup.sh catch-all"

# ── 8. Notifications
echo "-- notifications"
for t in backup_stale ini_set yml_apply yml_fail self_update; do
    grep -q "^${t}|" "${LIB}/notifications.sh" && pass "trigger ${t}" || fail "trigger ${t} missing"
done
grep -q 'self_update' "${LIB}/self-update.sh" && pass "self-update sends a notification" || fail "self-update notify"

# ── 8b. Two shell traps that abort commands silently under `set -e`
echo "-- set -e traps"
cat > "${TMP}/detect.py" <<'DPY'
import re, sys, glob, os
root = sys.argv[1]
files = [os.path.join(root, 'cipi')] + glob.glob(os.path.join(root, 'lib', '*.sh'))
bad = []

# 1. `local a="$1" b="...${a}..."` — bash expands ${a} before local assigns it.
for f in files:
    for n, line in enumerate(open(f, encoding='utf-8'), 1):
        st = line.strip()
        if not st.startswith(('local ', 'declare ')):
            continue
        body = st.split(None, 1)[1] if ' ' in st else ''
        names = [(m.group(1), m.start(1)) for m in re.finditer(r'(?:^|\s)([A-Za-z_][A-Za-z0-9_]*)=', body)]
        for i, (nm, pos) in enumerate(names):
            earlier = [x for x, _ in names[:i]]
            if not earlier:
                continue
            end = names[i + 1][1] if i + 1 < len(names) else len(body)
            val = body[pos:end]
            for e in earlier:
                if re.search(r'\$\{?' + re.escape(e) + r'\b', val):
                    bad.append('%s:%d self-referencing local: %s' % (os.path.basename(f), n, st))

# 2. a non-predicate helper whose last statement is a conditional AND-list
#    returns non-zero on the ordinary path and aborts its caller.
PREDICATES = {'app_exists', '_smtp_is_enabled', '_deploy_cfg_bool', 'nginx_default_server_enabled',
              '_bk_configured', '_bk_has_s3', 'php_is_installed', '_bk_profile_exists',
              '_zt_ssh_ingress_present'}
for f in files:
    lines = open(f, encoding='utf-8').read().split('\n')
    for i, l in enumerate(lines):
        if l.strip() != '}':
            continue
        j = i - 1
        while j >= 0 and (not lines[j].strip() or lines[j].strip().startswith('#')):
            j -= 1
        if j < 0:
            continue
        last = lines[j].strip()
        if not re.match(r'^(\[\[.*\]\]|\[.*\])\s*&&\s*\S', last):
            continue
        if 'return' in last or 'exit' in last:
            continue
        fn = '?'
        for k in range(j, -1, -1):
            m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{', lines[k])
            if m:
                fn = m.group(1)
                break
        if fn in PREDICATES:
            continue
        bad.append('%s:%d %s() ends with a conditional AND-list: %s' % (os.path.basename(f), j + 1, fn, last))

for b in bad:
    print(b)
sys.exit(1 if bad else 0)
DPY
if command -v python3 >/dev/null 2>&1; then
    dout=$(python3 "${TMP}/detect.py" "$ROOT" 2>&1)
    if [[ -z "$dout" ]]; then
        pass "no self-referencing 'local', no helper aborting on its normal path"
    else
        fail "shell traps present:"; echo "$dout" | sed 's/^/       /'
    fi
fi
grep -A3 '^_bk_app_paths()' "${LIB}/backup.sh" >/dev/null && grep -q 'return 0' <(sed -n '/^_bk_app_paths()/,/^}/p' "${LIB}/backup.sh") \
    && pass "_bk_app_paths returns 0 when there is nothing to archive" || fail "_bk_app_paths can abort a backup"
sed -n '/^_supervisor_remove_program()/,/^}/p' "${LIB}/common.sh" | grep -q 'return 0' \
    && pass "_supervisor_remove_program returns 0 (horizon enable no longer aborts)" || fail "_supervisor_remove_program can abort its caller"

# ── 8c. self-update must say why a download failed
echo "-- self-update diagnostics"
grep -q 'git clone .*2>/dev/null' "${LIB}/self-update.sh" \
    && fail "git's error is still discarded" || pass "git's error is no longer discarded"
grep -q 'Could not resolve\|could not resolve' "${LIB}/self-update.sh" && pass "DNS failure named" || fail "no DNS hint"
grep -q 'NAT gateway' "${LIB}/self-update.sh" && pass "blocked egress named" || fail "no egress hint"
grep -q 'does not exist on' "${LIB}/self-update.sh" && pass "missing branch named" || fail "no branch hint"
grep -q 'No space left' "${LIB}/self-update.sh" && pass "full disk named" || fail "no disk hint"
grep -q 'Reproduce it by hand' "${LIB}/self-update.sh" && pass "prints a command to reproduce it" || fail "no repro command"
grep -q '_cipi_run_timed 180 git clone' "${LIB}/self-update.sh" && pass "the clone cannot hang forever" || fail "clone has no timeout"

cat > "${TMP}/su.sh" <<'SU'
set -uo pipefail
RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
CIPI_LIB=LIBDIR; CIPI_CONFIG=/tmp/cipi-t; CIPI_LOG=/tmp/cipi-t; CIPI_VERSION=5.0.18
error(){ echo "ERR:$*"; }; step(){ :; }; info(){ :; }; success(){ :; }; warn(){ :; }
_cipi_run_timed(){ shift; "$@"; }
parse_args(){ :; }
ARG_check=""; ARG_branch=""
git(){ echo "$FAKE_ERR" >&2; return "${FAKE_RC:-128}"; }
source LIBDIR/self-update.sh
selfupdate_command
SU
sed -i.bak "s#LIBDIR#${LIB}#g" "${TMP}/su.sh" && rm -f "${TMP}/su.sh.bak"
o=$(FAKE_ERR="fatal: Could not resolve host: github.com" FAKE_RC=128 bash "${TMP}/su.sh" 2>&1)
[[ "$o" == *"Could not resolve host"* && "$o" == *"resolv.conf"* ]] \
    && pass "a DNS failure reports the real git message and the cause" || fail "DNS diagnosis (${o})"
o=$(FAKE_ERR="" FAKE_RC=124 bash "${TMP}/su.sh" 2>&1)
[[ "$o" == *"Timed out after 180s"* ]] && pass "a hung clone is reported as a timeout" || fail "timeout diagnosis (${o})"

# ── 9. Re-sourcing safety (cipi yml apply loads several libs)
echo "-- re-sourcing"
cat > "${TMP}/src.sh" <<'SS'
set -euo pipefail
CIPI_LIB=LIBDIR; CIPI_CONFIG=/tmp/cipi-t; CIPI_LOG=/tmp/cipi-t
RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
vault_read(){ echo '{}'; }; vault_write(){ cat >/dev/null; }
error(){ :; }; warn(){ :; }; info(){ :; }; success(){ :; }; step(){ :; }
source LIBDIR/app.sh;    source LIBDIR/app.sh
source LIBDIR/nginx.sh;  source LIBDIR/nginx.sh
source LIBDIR/backup.sh; source LIBDIR/backup.sh
SS
sed -i.bak "s#LIBDIR#${LIB}#g" "${TMP}/src.sh" && rm -f "${TMP}/src.sh.bak"
bash "${TMP}/src.sh" 2>/dev/null && pass "libs can be sourced twice in one process" || fail "double-source aborts"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
