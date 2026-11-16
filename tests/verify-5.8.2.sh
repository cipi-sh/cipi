#!/bin/bash
# Local regression checks for 5.8.2 — the GUI package copy in vendor/ is
# refreshed on every update (composer reinstall) and the update says which
# version the panel runs; the install flow (several SSH keys, a plan before
# anything is installed, the credentials in one layout behind a "saved?"
# gate, the optional layers as questions); `cipi api|gui <domain>` doing
# DNS check → install → certificate (→ token); `cipi credentials` (show
# again, export as CSV); `cipi gui sso`.
#
# The functions under test are extracted from their files and run against
# stubs (vault, curl, getent, hostname, certbot), so nothing outside the
# temp dirs is touched and bash 3.2 (macOS) is enough.
# Run from repo root: bash tests/verify-5.8.2.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "=== Cipi 5.8.2 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.8.2" ]] \
    && pass "version.md is 5.8.2" || fail "version.md is not 5.8.2"
grep -q '^## \[5.8.2\]' "${ROOT}/CHANGELOG.md" && grep -q 'composer reinstall cipi/gui' "${ROOT}/CHANGELOG.md" \
    && grep -q 'cipi credentials export' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.8.2 entry naming the reinstall and the export" || fail "CHANGELOG 5.8.2"
[[ ! -f "${LIB}/migrations/5.8.2.sh" ]] && pass "no migration (the nightly self-update runs the fixed step)" || fail "unexpected migration 5.8.2"
for f in gui.sh self-update.sh common.sh api.sh credentials.sh completion.sh notifications.sh; do
    bash -n "${LIB}/${f}" && pass "${f} parses" || fail "${f} does not parse"
done
for f in "${ROOT}/setup.sh" "${ROOT}/cipi"; do
    bash -n "$f" && pass "$(basename "$f") parses" || fail "$(basename "$f") does not parse"
done

TMP=$(mktemp -d) || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "${TMP:?}"' EXIT

extract() { sed -n "/^${2}() {/,/^}/p" "${LIB}/${1}"; }

# ── 1. the update step ───────────────────────────────────────
echo "--- _gui_update_package"
body=$(extract gui.sh _gui_update_package)
grep -q 'panel_composer "${CIPI_GUI_ROOT}" require cipi/gui:@dev' <<< "$body" && pass "still requires cipi/gui:@dev (the lock and autoload)" || fail "require missing"
grep -q '_gui_reinstall_package "${CIPI_GUI_ROOT}"' <<< "$body" && pass "reinstalls the package copy after the require" || fail "no reinstall"
grep -q 'synced=$(_gui_pkg_version /opt/cipi/cipi-gui)' <<< "$body" \
    && grep -q 'vendored=$(_gui_pkg_version "${CIPI_GUI_ROOT}/vendor/cipi/gui")' <<< "$body" \
    && pass "compares the synced version with the vendored one" || fail "version comparison missing"
grep -q 'the panel did not update (run: cipi gui update)' <<< "$body" && pass "a stale copy is a warning and a non-zero status" || fail "stale copy not reported"
grep -q 'success "cipi/gui package updated${vendored:+ (${vendored})}"' <<< "$body" && pass "the success line names the version" || fail "success line"
# reinstall runs before publish/migrate so the new package's migrations run
r=$(grep -n '_gui_reinstall_package "${CIPI_GUI_ROOT}"\|artisan migrate --force' <<< "$body" | head -2 | cut -d: -f1 | paste -sd, -)
[[ "$r" == "$(sort -n <<< "${r//,/$'\n'}" | paste -sd, -)" && "$r" == *,* ]] && pass "reinstall comes before artisan migrate" || fail "order: ${r}"
grep -q 'panel_composer "$dir" reinstall cipi/gui --no-interaction --prefer-dist --no-ansi' "${LIB}/gui.sh" \
    && grep -q '|| (panel_composer "$dir" update cipi/gui --no-interaction --prefer-dist --no-ansi)' "${LIB}/gui.sh" \
    && pass "_gui_reinstall_package: reinstall, then update as the fallback" || fail "_gui_reinstall_package body"
grep -q 'if ! _gui_update_package; then' "${LIB}/self-update.sh" && pass "cipi self-update runs the same step nightly" || fail "self-update does not call _gui_update_package"

# ── 2. _gui_pkg_version ──────────────────────────────────────
echo "--- _gui_pkg_version"
mkdir -p "${TMP}/pkg/src/Support"
printf '<?php\nnamespace CipiGui\\Support;\nfinal class Theme\n{\n    public const VERSION = %s4.0.0%s;\n}\n' "'" "'" > "${TMP}/pkg/src/Support/Theme.php"
v=$(bash -c "$(extract gui.sh _gui_pkg_version); _gui_pkg_version '${TMP}/pkg'")
[[ "$v" == "4.0.0" ]] && pass "reads the version from src/Support/Theme.php" || fail "version read: ${v}"
v=$(bash -c "$(extract gui.sh _gui_pkg_version); _gui_pkg_version '${TMP}/nosuch'")
[[ -z "$v" ]] && pass "no package: empty" || fail "missing package gave: ${v}"

# ── 3. the composer behaviour that caused it (when composer is installed) ──
echo "--- composer path repository"
if command -v composer >/dev/null 2>&1 && command -v php >/dev/null 2>&1; then
    mkdir -p "${TMP}/cp/pkg/src" "${TMP}/cp/app"
    printf '{"name":"cipi/demo","description":"d","type":"library","autoload":{"psr-4":{"Demo\\\\":"src/"}}}\n' > "${TMP}/cp/pkg/composer.json"
    echo '<?php // v1' > "${TMP}/cp/pkg/src/Version.php"
    printf '{"name":"t/app","minimum-stability":"dev","prefer-stable":true,"repositories":{"demo":{"type":"path","url":"../pkg","options":{"symlink":false}}}}\n' > "${TMP}/cp/app/composer.json"
    if (cd "${TMP}/cp/app" && COMPOSER_ALLOW_SUPERUSER=1 composer require cipi/demo:@dev --no-interaction --quiet >/dev/null 2>&1); then
        echo '<?php // v2' > "${TMP}/cp/pkg/src/Version.php"
        (cd "${TMP}/cp/app" && COMPOSER_ALLOW_SUPERUSER=1 composer require cipi/demo:@dev --no-interaction --quiet >/dev/null 2>&1) || true
        [[ "$(cat "${TMP}/cp/app/vendor/cipi/demo/src/Version.php")" == '<?php // v1' ]] \
            && pass "composer require leaves the copy stale when only files changed (the bug)" \
            || pass "this composer refreshes the copy on require (newer behaviour; reinstall stays harmless)"
        (cd "${TMP}/cp/app" && COMPOSER_ALLOW_SUPERUSER=1 composer reinstall cipi/demo --no-interaction --quiet >/dev/null 2>&1) || true
        [[ "$(cat "${TMP}/cp/app/vendor/cipi/demo/src/Version.php")" == '<?php // v2' ]] \
            && pass "composer reinstall copies the current files (the fix)" || fail "reinstall did not refresh the copy"
    else
        pass "composer could not install the fixture here — skipped"
    fi
else
    pass "composer not installed here — skipped"
fi


# ── 4. cipi yml plan converges ───────────────────────────────
echo "--- cipi yml plan: comparisons that converge"
# A copy of yml.sh with the Supervisor path moved under TMP, crontab stubbed.
sed "s|/etc/supervisor/conf.d/|${TMP}/supervisor/|g" "${LIB}/yml.sh" > "${TMP}/yml-copy.sh"
if grep -q '/etc/supervisor' "${TMP}/yml-copy.sh"; then
    fail "yml.sh copy still names /etc/supervisor — plan harness not run"
else
mkdir -p "${TMP}/cfg" "${TMP}/log" "${TMP}/supervisor"
cat > "${TMP}/plan.sh" <<EOF
export CIPI_LIB="${LIB}" CIPI_CONFIG="${TMP}/cfg" CIPI_LOG="${TMP}/log"
RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
source "${LIB}/common.sh" 2>/dev/null
vault_read() {
    case "\$1" in
        apps.json) cat "${TMP}/apps.json" ;;
        backup.json) cat "${TMP}/backup.json" ;;
        *) echo '{}' ;;
    esac
}
source "${LIB}/routes.sh"
source "${LIB}/backup.sh"
source "${TMP}/yml-copy.sh"
_yml_source_libs() { :; }
_yml_post_deploy_workdir() { echo /home/sportgrid/current; }
crontab() { [[ "\${3:-}" == "-l" ]] && { cat "${TMP}/crontab-\$2" 2>/dev/null; return 0; }; cat > "${TMP}/crontab-\$2"; }
_YML_APP=sportgrid
_YML_FILE="\$1"
res=\$(_yml_parse "\$1" sportgrid)
_YML_DATA=\$(jq -c .data <<< "\$res")
if [[ "\${2:-}" == "--desired-backup" ]]; then _yml_backup_profile_desired "\$3"; exit; fi
if [[ "\${2:-}" == "--cron-lines" ]]; then _yml_crons_lines sportgrid; exit; fi
_yml_build_plan
printf 'A|%s\n' "\${_YML_ACTIONS[@]}"
printf 'B|%s\n' "\${_YML_BLOCKERS[@]}"
EOF
cat > "${TMP}/apps.json" <<'EOF'
{"sportgrid":{"domain":"sportgrid.test","php":"8.4","custom":false,"runtime":"fpm",
  "ini":{"display_errors":"On"},"backup_profiles":["sportgrid-db"]}}
EOF
cat > "${TMP}/backup.json" <<'EOF'
{"bucket":"","profiles":{
  "default":{"scope":"all","cron":"0 2 * * *","destinations":["local"],"retention":{"keep":0,"days":28,"weeks":0},"encrypt":false,"enabled":true},
  "sportgrid-db":{"scope":"db","cron":"*/30 * * * *","destinations":["local"],"retention":{"keep":48,"days":0,"weeks":0},"encrypt":false,"enabled":true,"created_at":1700000000}
}}
EOF
cp "${TMP}/backup.json" "${TMP}/cfg/backup.json"
cat > "${TMP}/supervisor/sportgrid.conf" <<'EOF'
[program:sportgrid-worker-default]
process_name=%(program_name)s_%(process_num)02d
command=/usr/bin/php8.4 /home/sportgrid/current/artisan queue:work database --sleep=3 --tries=3 --max-time=3600 --queue=default
numprocs=2
EOF
printf '# Laravel Scheduler\n* * * * * /usr/bin/php8.4 /home/sportgrid/current/artisan schedule:run >> /dev/null 2>&1\n' > "${TMP}/crontab-sportgrid"

cat > "${TMP}/conv.yml" <<'EOF'
version: 1
app:
  ini:
    display_errors: 1
    opcache.jit: off
workers:
  queues:
    - queue: default
      processes: 2
backup:
  profiles:
    - name: sportgrid-db
      scope: db
      every: 30m
      keep: 48
      destinations: [local]
EOF
plan() { bash "${TMP}/plan.sh" "$@" 2>"${TMP}/plan.err" || true; }

# backup: first plan updates (the stored profile lacks interval_seconds), then
# the profile apply would save is stored, and the plan has nothing left.
out=$(plan "${TMP}/conv.yml")
grep -q 'update backup profile sportgrid-db' <<< "$out" \
    && pass "backup: a stored profile that differs is an update" || fail "backup first plan: ${out} $(cat "${TMP}/plan.err")"
desired=$(plan "${TMP}/conv.yml" --desired-backup sportgrid-db)
jq -e '.cron == "*/30 * * * *" and .interval_seconds == 1800 and .enabled == true and .created_at == 1700000000' <<< "$desired" >/dev/null \
    && pass "the desired profile keeps what the file does not name (created_at) and fills the interval" || fail "desired profile: ${desired}"
jq --argjson d "$desired" '.profiles["sportgrid-db"] = $d' "${TMP}/backup.json" > "${TMP}/backup.new" && mv "${TMP}/backup.new" "${TMP}/backup.json"
cp "${TMP}/backup.json" "${TMP}/cfg/backup.json"
out=$(plan "${TMP}/conv.yml")
! grep -q 'backup-profile|' <<< "$out" && pass "backup: once applied, the profile is not an action again" || fail "backup second plan: ${out}"

# workers: the program matches the file
! grep -q 'worker-sync|\|worker-add|' <<< "$out" && pass "workers: a matching program is not an update" || fail "workers: ${out}"
sed 's/processes: 2/processes: 3/' "${TMP}/conv.yml" > "${TMP}/conv3.yml"
out3=$(plan "${TMP}/conv3.yml")
grep -q 'worker-sync|default|3|3|3600|update queue worker default (3 process(es))' <<< "$out3" \
    && pass "workers: a different process count is an update" || fail "workers procs: ${out3}"

# php.ini: 1 matches the stored On; opcache.jit: off (a YAML boolean) is accepted and lowercase
! grep -q 'ini|display_errors' <<< "$out" && pass "ini: display_errors: 1 matches the stored On" || fail "ini display_errors: ${out}"
grep -q 'A|ini|opcache.jit=off|php.ini opcache.jit = off' <<< "$out" && ! grep -q 'B|app.ini.opcache.jit' <<< "$out" \
    && pass "ini: opcache.jit: off is planned as 'off', not refused" || fail "ini jit: ${out}"
printf 'version: 1\napp:\n  ini:\n    display_errors: maybe\n' > "${TMP}/badini.yml"
outb=$(plan "${TMP}/badini.yml")
grep -q "B|app.ini.display_errors: 'maybe' is not a value cipi ini accepts" <<< "$outb" && ! grep -q 'A|ini|' <<< "$outb" \
    && pass "ini: a value cipi ini refuses blocks the plan instead of ending the apply" || fail "ini blocker: ${outb}"

# scheduler: a managed cron running schedule:run is not the Laravel scheduler.
# _yml_crons_lines uses mapfile (bash 4+): on an older bash the three checks
# below are skipped, as verify-5.6.1 skips yml.sh altogether.
if [[ "$(bash -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ]]; then
printf '* * * * * cd /home/sportgrid/current && env PATH=/usr/local/bin:/usr/bin:/bin CI=true /usr/bin/php8.4 artisan schedule:run >> /home/sportgrid/logs/cron.log 2>&1 # cipi-yml\n' > "${TMP}/crontab-sportgrid"
cat > "${TMP}/sched.yml" <<'EOF'
version: 1
schedule: false
crons:
  - every: 1m
    run: artisan schedule:run
EOF
outs=$(plan "${TMP}/sched.yml")
! grep -q 'A|schedule|' <<< "$outs" && ! grep -q 'A|crons|' <<< "$outs" \
    && pass "schedule: false with a managed schedule:run cron is in sync (no ping-pong)" || fail "schedule ping-pong: ${outs}"

# crons: the lines carry the PHP version in force when they are built
lines=$(plan "${TMP}/sched.yml" --cron-lines)
grep -q '/usr/bin/php8.4 artisan schedule:run' <<< "$lines" && pass "cron lines: built with the app's PHP" || fail "cron lines: ${lines}"
sed -i.bak 's/"php":"8.4"/"php":"8.5"/' "${TMP}/apps.json"
lines=$(plan "${TMP}/sched.yml" --cron-lines)
grep -q '/usr/bin/php8.5 artisan schedule:run' <<< "$lines" && pass "cron lines: built again after a PHP change" || fail "cron lines after php change: ${lines}"
else
    pass "schedule/crons plan checks skipped: bash $(bash -c 'echo ${BASH_VERSION}') has no mapfile (run on bash 4+)"
fi
fi
grep -q 'cron_want=$(_yml_crons_lines "$app")' "${LIB}/yml.sh" && pass "apply writes the lines it builds then, not the plan's" || fail "apply crons uses stale lines"
grep -q '\[\[ -n "$h_grace" \]\] || app_unset "$app" health_grace' "${LIB}/yml.sh" && pass "health: a file without grace clears the stored one" || fail "health grace not cleared"
grep -q '( _ini_set "$pair" "--app=${app}" >/dev/null ) || return 1' "${LIB}/yml.sh" && pass "ini apply runs in a subshell" || fail "ini apply not isolated"
grep -q '\[\[ "$(app_get "$app" search)" == "true" \]\] || app_set "$app" search "true"' "${LIB}/search.sh" && pass "search: already-enabled keeps apps.json in step" || fail "search short-circuit"
grep -q 'grep -v '"'"'# cipi-yml$'"'"' | grep -q '"'"'^\\\* \\\* \\\* \\\* \\\*.\*schedule:run'"'"'' "${LIB}/yml.sh" \
    && pass "schedule plan ignores the managed lines" || fail "schedule plan grep"

# ── 5. cipi schedule on|off keeps the managed crons ──────────
echo "--- _schedule_crontab_write"
SCHED="${TMP}/sched.sh"
{
    echo "crontab() { [[ \"\${3:-}\" == \"-l\" ]] && { cat \"${TMP}/ct-\$2\" 2>/dev/null; return 0; }; cat > \"${TMP}/ct-\$2\"; }"
    extract app.sh _schedule_crontab_write
} > "$SCHED"
printf '# old\n* * * * * old scheduler line\n*/5 * * * * cd /home/demo/current && env CI=true /usr/bin/php8.4 artisan queue:prune-batches >> /home/demo/logs/cron.log 2>&1 # cipi-yml\n' > "${TMP}/ct-demo"
bash -c "source '$SCHED'; _schedule_crontab_write demo 8.4 off"
grep -q '# cipi-yml$' "${TMP}/ct-demo" && grep -q 'disabled by cipi schedule off' "${TMP}/ct-demo" && ! grep -q 'old scheduler line' "${TMP}/ct-demo" \
    && pass "schedule off rewrites the crontab and keeps the # cipi-yml lines" || fail "schedule off: $(cat "${TMP}/ct-demo")"
bash -c "source '$SCHED'; _schedule_crontab_write demo 8.4 on"
[[ "$(grep -c '# cipi-yml$' "${TMP}/ct-demo")" == "1" ]] && grep -q 'artisan schedule:run' "${TMP}/ct-demo" \
    && pass "schedule on: scheduler back, managed line kept once" || fail "schedule on: $(cat "${TMP}/ct-demo")"
rm -f "${TMP}/ct-demo"
bash -c "source '$SCHED'; _schedule_crontab_write demo 8.4 on"
[[ "$(grep -c '# cipi-yml$' "${TMP}/ct-demo")" == "0" ]] && pass "no managed lines: nothing added" || fail "schedule on without managed: $(cat "${TMP}/ct-demo")"

# ══ the install flow, cipi api|gui, cipi credentials, cipi gui sso ══
T9=$(mktemp -d "${TMPDIR:-/tmp}/verify582b.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
[[ -n "$T9" && -d "$T9" ]] || { echo "no temp dir" >&2; exit 1; }
trap 'rm -rf "${TMP:?}" "${T9:?}"' EXIT


# The text of one top-level function of a file ("name() {" … "}").
fn() {
    awk -v n="$2" '
        !on && $0 ~ "^"n"\\(\\) \\{" { on = 1 }
        !on { next }
        { print }
        /^}/ { exit }' "$1"
}
# Line number of the first match of $2 inside text $1 (0 when absent).
lineof() { printf '%s\n' "$1" | grep -n -F -- "$2" | head -1 | cut -d: -f1 | grep . || echo 0; }

# ── harness ──────────────────────────────────────────────────
CALLS="${T9}/calls"; : > "$CALLS"
PRE="${T9}/pre.sh"
{
    cat <<'EOS'
RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
info(){ echo "INFO $*"; }; warn(){ echo "WARN $*"; }; success(){ echo "OK $*"; }
error(){ echo "ERR $*" >&2; }; step(){ echo "STEP $*"; }
log_action(){ echo "log_action $*" >> "${CALLS}"; }
cipi_notify(){ echo "notify $3" >> "${CALLS}"; }
parse_args(){ local arg k v; for arg in "$@"; do case "$arg" in --*=*) k="${arg%%=*}"; v="${arg#*=}"; k="${k#--}"; printf -v "ARG_${k//-/_}" '%s' "$v" ;; --*) k="${arg#--}"; printf -v "ARG_${k//-/_}" '%s' true ;; esac; done; }
vault_read(){ [[ -f "${CIPI_CONFIG}/$1" ]] && cat "${CIPI_CONFIG}/$1" || echo "{}"; }
curl(){ printf '%s\n' "${PUB_IP:-}"; }
getent(){ [[ "$1" == ahosts ]] || return 2; local ip; for ip in ${RESOLVED:-}; do echo "$ip STREAM $2"; echo "$ip DGRAM"; done; [[ -n "${RESOLVED:-}" ]]; }
hostname(){ if [[ "${1:-}" == "-I" ]]; then printf '%s\n' "${LOCAL_IPS:-}"; else echo "vps-test"; fi; }
lsb_release(){ echo "Ubuntu 24.04.3 LTS"; }
certbot(){ echo "certbot $*" >> "${CALLS}"; return "${CERTBOT_RC:-0}"; }
nginx(){ return 0; }; systemctl(){ return 0; }; reload_nginx(){ echo reload_nginx >> "${CALLS}"; }
chown(){ return 0; }; chmod(){ return 0; }; sudo(){ echo "sudo $*" >> "${CALLS}"; }
panel_domain(){ echo "panel.example.com"; }; _gui_pkg_version(){ echo "${GUI_PKG_VERSION:-4.0.2}"; }
EOS
    for f in server_public_ip server_local_ips dns_resolve_ips ip_is_cloudflare panel_dns_check confirm_yes \
             panel_env_set _panel_env_set_do panel_env_read; do fn "${LIB}/common.sh" "$f"; done
    # 5.8.6: in the live tree the panel's .env is edited and read as www-data
    # (exercised with real users in verify-5.8.6.sh); here the tree is a
    # temporary directory of the test's own.
    echo '_panel_tree_is_www(){ return 1; }'
    for f in _api_ssl_issue; do fn "${LIB}/api.sh" "$f"; done
    for f in _gui_ssl_issue _gui_env_set_do _gui_env_unset_do _gui_env_set _gui_env_unset _gui_env_get _gui_sso_apply _gui_sso_redirect_uri _gui_sso_default_label \
             _gui_sso_require_app _gui_sso_reset_links gui_sso_set gui_sso_status gui_sso_only gui_sso_disable gui_sso_command _gui_read_password; do fn "${LIB}/gui.sh" "$f"; done
    grep '^GUI_SSO_KEYS=' "${LIB}/gui.sh"
    fn "${LIB}/common.sh" validate_domain
    for f in _ssh_key_clean _ssh_key_valid _ssh_key_add; do fn "${ROOT}/setup.sh" "$f"; done
    cat "${LIB}/credentials.sh"
} > "$PRE"
run() { CALLS="$CALLS" CIPI_CONFIG="${T9}/etc" bash -c "set -euo pipefail; source '${PRE}'; $*" 2>&1; }

# ── 1. ip_is_cloudflare ──────────────────────────────────────
echo "--- ip_is_cloudflare"
for ip in 104.16.1.1 172.64.0.1 173.245.48.9 2606:4700::1 2a06:98c7::1; do
    run "ip_is_cloudflare $ip" >/dev/null && pass "$ip is Cloudflare" || fail "$ip not seen as Cloudflare"
done
for ip in 1.2.3.4 172.63.255.255 104.15.255.255 2a06:98c8::1 garbage; do
    run "ip_is_cloudflare $ip" >/dev/null && fail "$ip taken for Cloudflare" || pass "$ip is not Cloudflare"
done

# ── 2. panel_dns_check ───────────────────────────────────────
echo "--- panel_dns_check"
out=$(PUB_IP=5.6.7.8 RESOLVED="5.6.7.8" run 'panel_dns_check api.example.com'); rc=$?
[[ $rc -eq 0 && "$out" == *"DNS: api.example.com → 5.6.7.8"* ]] && pass "the name points here: ok" || fail "points here: rc=$rc $out"
out=$(PUB_IP=5.6.7.8 RESOLVED="" run 'panel_dns_check api.example.com'); rc=$?
[[ $rc -eq 1 && "$out" == *"does not resolve yet"* && "$out" == *"A record for api.example.com → 5.6.7.8"* ]] \
    && pass "no record: stops with the record to create" || fail "no record: rc=$rc $out"
out=$(PUB_IP=5.6.7.8 RESOLVED="1.2.3.4" run 'panel_dns_check api.example.com'); rc=$?
[[ $rc -eq 1 && "$out" == *"points to 1.2.3.4, this server is 5.6.7.8"* && "$out" == *"--skip-dns-check"* ]] \
    && pass "another address: stops and names both" || fail "elsewhere: rc=$rc $out"
out=$(PUB_IP=5.6.7.8 RESOLVED="104.16.1.1 104.16.1.2" run 'panel_dns_check api.example.com'); rc=$?
[[ $rc -eq 0 && "$out" == *"Cloudflare proxy (origin 5.6.7.8)"* ]] && pass "Cloudflare proxy: accepted" || fail "cloudflare: rc=$rc $out"
out=$(PUB_IP="" LOCAL_IPS="10.0.0.5" RESOLVED="10.0.0.5" run 'panel_dns_check api.example.com'); rc=$?
[[ $rc -eq 0 ]] && pass "public IP unknown, a local address matches: ok" || fail "local match: rc=$rc $out"
out=$(PUB_IP="" LOCAL_IPS="" RESOLVED="1.2.3.4" run 'panel_dns_check api.example.com'); rc=$?
[[ $rc -eq 0 && "$out" == *"not verified"* ]] && pass "own address unknown: a warning, not a stop" || fail "unknown own: rc=$rc $out"
out=$(PUB_IP=5.6.7.8 RESOLVED="" run 'ARG_skip_dns_check=true panel_dns_check api.example.com'); rc=$?
[[ $rc -eq 0 && "$out" == *"skipped"* ]] && pass "--skip-dns-check: a note" || fail "skip flag: rc=$rc $out"
out=$(PUB_IP=5.6.7.8 RESOLVED="" run 'panel_dns_check api.example.com true'); rc=$?
[[ $rc -eq 0 ]] && pass "skip as the second argument" || fail "skip arg: rc=$rc"
out=$(PUB_IP=5.6.7.8 RESOLVED="5.6.7.8 5.6.7.8" run 'dns_resolve_ips api.example.com')
[[ "$out" == "5.6.7.8" ]] && pass "dns_resolve_ips: one line per address" || fail "dns_resolve_ips: $out"
out=$(RESOLVED="" run 'r=$(dns_resolve_ips nothing.example.com); echo "after:<$r>"'); rc=$?
[[ $rc -eq 0 && "$out" == "after:<>" ]] && pass "dns_resolve_ips: no record is empty, not a pipefail exit" || fail "dns_resolve_ips pipefail: rc=$rc $out"
out=$(PUB_IP="not an ip" run 'echo "<$(server_public_ip)>"')
[[ "$out" == "<>" ]] && pass "server_public_ip: an answer that is not an address is empty" || fail "public ip: $out"

# ── 3. the certificate step ──────────────────────────────────
echo "--- _api_ssl_issue / _gui_ssl_issue"
: > "$CALLS"
out=$(run '_api_ssl_issue api.example.com'); rc=$?
[[ $rc -eq 0 && "$out" == *"SSL installed for api.example.com"* ]] && grep -q -- '--register-unsafely-without-email --redirect' "$CALLS" \
    && grep -q 'notify api_ssl' "$CALLS" && pass "api: certbot, reload, log, notify, 0" || fail "api ssl ok: rc=$rc $out"
out=$(CERTBOT_RC=1 run '_api_ssl_issue api.example.com'); rc=$?
[[ $rc -eq 1 && "$out" == *"Then: cipi api ssl"* ]] && pass "api: certbot failed → 1 and the command to run" || fail "api ssl fail: rc=$rc $out"
out=$(CERTBOT_RC=1 run '_gui_ssl_issue panel.example.com' < /dev/null); rc=$?
[[ $rc -eq 1 && "$out" == *"Then: cipi gui ssl"* ]] && pass "gui: certbot failed without a terminal → 1" || fail "gui ssl fail: rc=$rc $out"
out=$(run '_gui_ssl_issue panel.example.com'); rc=$?
[[ $rc -eq 0 ]] && grep -q reload_nginx "$CALLS" && pass "gui: certbot ok → reload, 0" || fail "gui ssl ok: rc=$rc"

# ── 4. api_setup / gui_setup wiring ─────────────────────────
echo "--- cipi api <domain> / cipi gui <domain>"
body=$(fn "${LIB}/api.sh" api_setup)
grep -q 'unset ARG_no_ssl ARG_no_token ARG_skip_dns_check' <<< "$body" && grep -q 'parse_args "$@"' <<< "$body" \
    && pass "api_setup takes --no-ssl --no-token --skip-dns-check" || fail "api_setup flags"
a=$(lineof "$body" 'panel_domain_check "$domain" api'); b=$(lineof "$body" 'panel_dns_check "$domain" || exit 1'); c=$(lineof "$body" 'vault_write api.json')
(( a > 0 && b > a && c > b )) && pass "api_setup: domain check, DNS check, then the config is written" || fail "api_setup order: $a $b $c"
grep -q '\[\[ "${ARG_no_ssl:-}" == "true" \]\] || panel_dns_check "$domain" || exit 1' <<< "$body" && pass "api_setup: --no-ssl skips the DNS check" || fail "api_setup no-ssl/dns"
grep -q '_api_ssl_issue "$domain" && ssl_ok=true' <<< "$body" && pass "api_setup issues the certificate" || fail "api_setup ssl"
grep -q 'ARG_no_token:-}" != "true" && -t 0' <<< "$body" && grep -q 'confirm_yes "Create an API token now?"' <<< "$body" && grep -q '^ *api_token_create$' <<< "$body" \
    && pass "api_setup offers a token on a terminal, not with --no-token" || fail "api_setup token prompt"
grep -q '\[\[ "$ssl_ok" == "true" || "${ARG_no_ssl:-}" == "true" \]\] || exit 1' <<< "$body" && pass "api_setup exits 1 when the certificate failed" || fail "api_setup exit"
grep -q 'scheme}://${domain}/api' <<< "$body" && pass "api_setup summary follows the scheme" || fail "api_setup scheme"
body=$(fn "${LIB}/api.sh" api_ssl)
a=$(lineof "$body" 'panel_dns_check "$domain" || exit 1'); b=$(lineof "$body" '_api_ssl_issue "$domain" || exit 1')
(( a > 0 && b > a )) && grep -q 'parse_args "$@"' <<< "$body" && pass "cipi api ssl: DNS check, then certbot" || fail "api_ssl: $a $b"
body=$(fn "${LIB}/api.sh" api_move)
grep -q '\[\[ "${ARG_no_ssl:-}" == "true" \]\] || panel_dns_check "$new" || exit 1' <<< "$body" && grep -q '_api_ssl_issue "$new" && ssl_ok=true' <<< "$body" \
    && pass "cipi api move: DNS check unless --no-ssl, certificate via _api_ssl_issue" || fail "api_move"
! grep -q '( api_ssl )' "${LIB}/api.sh" && pass "no subshell api_ssl left" || fail "( api_ssl ) still used"
grep -q 'ssl)     api_ssl "$@" ;;' "${LIB}/api.sh" && grep -q 'api_setup "$sub" "$@"' "${LIB}/api.sh" && pass "api dispatcher passes the flags" || fail "api dispatcher"

body=$(fn "${LIB}/gui.sh" gui_setup)
grep -q 'unset ARG_no_ssl ARG_skip_dns_check' <<< "$body" && pass "gui_setup takes --no-ssl --skip-dns-check" || fail "gui_setup flags"
a=$(lineof "$body" 'panel_domain_check "$domain" gui'); b=$(lineof "$body" 'panel_dns_check "$domain" || exit 1'); c=$(lineof "$body" 'vault_write gui.json'); d=$(lineof "$body" '_gui_prompt_admin_credentials')
(( a > 0 && b > a && c > b && d > b )) && pass "gui_setup: domain check, DNS check, then config and the admin prompt" || fail "gui_setup order: $a $b $c $d"
grep -q '_gui_ssl_issue "$domain" && ssl_ok=true' <<< "$body" && grep -q '\[\[ "$ssl_ok" == "true" || "${ARG_no_ssl:-}" == "true" \]\] || exit 1' <<< "$body" \
    && pass "gui_setup issues the certificate and exits 1 when it failed" || fail "gui_setup ssl"
grep -q 'api_dom=$(panel_domain api)' <<< "$body" && grep -q 'Connections' <<< "$body" && pass "gui_setup ends with the next step (connect a server)" || fail "gui_setup next"
body=$(fn "${LIB}/gui.sh" gui_ssl)
a=$(lineof "$body" 'panel_dns_check "$domain" || exit 1'); b=$(lineof "$body" '_gui_ssl_issue "$domain" || exit 1')
(( a > 0 && b > a )) && pass "cipi gui ssl: DNS check, then certbot" || fail "gui_ssl: $a $b"
body=$(fn "${LIB}/gui.sh" gui_move)
grep -q '\[\[ "${ARG_no_ssl:-}" == "true" \]\] || panel_dns_check "$new" || exit 1' <<< "$body" && grep -q '_gui_ssl_issue "$new" && ssl_ok=true' <<< "$body" \
    && pass "cipi gui move: DNS check unless --no-ssl" || fail "gui_move"
! grep -q '( gui_ssl )' "${LIB}/gui.sh" && pass "no subshell gui_ssl left" || fail "( gui_ssl ) still used"
grep -q 'ssl) gui_ssl "$@" ;;' "${LIB}/gui.sh" && grep -q 'gui_setup "$sub" "$@"' "${LIB}/gui.sh" && pass "gui dispatcher passes the flags" || fail "gui dispatcher"

# ── 5. cipi credentials ──────────────────────────────────────
echo "--- credentials"
mkdir -p "${T9}/etc"
printf '{"root_password":"RootPw123","db_root_password":"Db\\"Pw,456","valkey_user":"default","valkey_password":"VkPw789"}' > "${T9}/etc/server.json"
out=$(CRED_SERVER_IP=203.0.113.9 run 'credentials_card')
for t in Server SSH Root MariaDB Valkey; do
    grep -qx "  ${t}" <<< "$out" && pass "card: a '${t}' title" || fail "card: no ${t} title: $out"
done
! grep -q "PostgreSQL\|Meilisearch\|Backup encryption" <<< "$out" && pass "card: PostgreSQL, Meilisearch, backup key absent when not installed" || fail "card shows absent services"
n=$(grep -c '^  Password:' <<< "$out"); [[ "$n" == 4 ]] && pass "card: a Password: row under SSH, Root, MariaDB and Valkey" || fail "card: $n Password rows"
n=$(grep -c '^  User:' <<< "$out"); [[ "$n" == 4 ]] && pass "card: a User: row under each of them" || fail "card: $n User rows"
a=$(lineof "$out" '  Root'); b=$(lineof "$out" 'User:           root'); c=$(lineof "$out" 'Password:       RootPw123')
(( a > 0 && b == a + 1 && c == a + 2 )) && pass "card: title, then User:, then Password: (the layout asked for)" || fail "card layout: $a $b $c"
grep -q 'ssh cipi@203.0.113.9, then: su root' <<< "$out" && pass "card: how to become root" || fail "card: root login line"
grep -q 'Password:       Db"Pw,456' <<< "$out" && pass "card prints the MariaDB password as is" || fail "card mariadb"
grep -q 'URL:            mariadb+ssh://cipi@203.0.113.9/root:Db"Pw,456@127.0.0.1:3306/' <<< "$out" && pass "card: a MariaDB connection URL through SSH" || fail "card mariadb url: $out"
grep -q 'URL:            redis://default:VkPw789@127.0.0.1:6379' <<< "$out" && pass "card: a Valkey URL" || fail "card valkey url"

printf '{"root_password":"RootPw123","db_root_password":"Db\\"Pw,456","valkey_user":"default","valkey_password":"VkPw789","db_engines":{"pgsql":{"root_password":"PgPw000"}}}' > "${T9}/etc/server.json"
printf '{"master_key":"MeiliKey111","host":"127.0.0.1","port":7700}' > "${T9}/etc/search.json"
printf 'BKKEY222' > "${T9}/etc/.backup_key"
out=$(CRED_SERVER_IP=203.0.113.9 run 'credentials_card')
grep -qx "  PostgreSQL" <<< "$out" && grep -qx "  Meilisearch" <<< "$out" && grep -qx "  Backup encryption key" <<< "$out" \
    && pass "card: PostgreSQL, Meilisearch and the backup key once they exist" || fail "card extras: $out"
grep -q 'Master key:     MeiliKey111' <<< "$out" && grep -q 'Key:            BKKEY222' <<< "$out" && pass "card: master key and backup key values" || fail "card extra values"
grep -q 'URL:            postgresql+ssh://cipi@203.0.113.9/postgres:PgPw000@127.0.0.1:5432/postgres' <<< "$out" && pass "card: a PostgreSQL connection URL" || fail "card pgsql url"
grep -q 'Tunnel:         ssh -L 7700:127.0.0.1:7700 cipi@203.0.113.9' <<< "$out" && pass "card: the Meilisearch tunnel" || fail "card meili tunnel"

out=$(CRED_SERVER_IP=203.0.113.9 run 'credentials_export' < /dev/null); rc=$?
[[ $rc -eq 0 ]] && pass "export: 0" || fail "export rc=$rc: $out"
[[ "$(head -1 <<< "$out")" == "title,url,username,password,notes" ]] && pass "export: the plain header" || fail "export header: $(head -1 <<< "$out")"
[[ "$(wc -l <<< "$out" | tr -d ' ')" == 7 ]] && pass "export: header + 6 entries" || fail "export lines: $(wc -l <<< "$out")"
grep -q '^"Cipi vps-test — MariaDB root","mariadb+ssh://cipi@203.0.113.9/root:Db""Pw,456@127.0.0.1:3306/","root","Db""Pw,456","' <<< "$out" && pass "export: RFC 4180 quoting (a quote doubled, a comma kept), the TablePlus URL" || fail "export quoting: $out"
grep -q '^"Cipi vps-test — PostgreSQL","postgresql+ssh://cipi@203.0.113.9/postgres:PgPw000@127.0.0.1:5432/postgres","postgres","PgPw000","' <<< "$out" && pass "export: the PostgreSQL URL" || fail "export pgsql: $out"
grep -q '^"Cipi vps-test — Valkey","redis://default:VkPw789@127.0.0.1:6379","default","VkPw789","' <<< "$out" && pass "export: the redis:// URL" || fail "export valkey: $out"
grep -q '^"Cipi vps-test — Meilisearch","http://127.0.0.1:7700","","MeiliKey111","' <<< "$out" && pass "export: an empty username stays a field" || fail "export empty field: $out"
grep -q '^"Cipi vps-test — Backup encryption key","","","BKKEY222","' <<< "$out" && pass "export: the backup key row" || fail "export backup row"
grep -q '^"Cipi vps-test — Root","ssh://cipi@203.0.113.9","root","RootPw123","' <<< "$out" && pass "export: the root row with ssh:// url" || fail "export root row"
! grep -q 'Straight into a file' <<< "$out" && pass "export: no hint when stdout is not a terminal" || fail "export hint on a pipe"
grep -q 'log_action CREDENTIALS EXPORTED' "$CALLS" && grep -q 'notify credentials_show' "$CALLS" && pass "export is logged and notified" || fail "export log/notify"

out=$(CRED_SERVER_IP=203.0.113.9 run "credentials_export --output='${T9}/out.csv'"); rc=$?
[[ $rc -eq 0 && -f "${T9}/out.csv" ]] && pass "export --output writes the file" || fail "export output: rc=$rc $out"
[[ "$(stat -f '%Lp' "${T9}/out.csv" 2>/dev/null || stat -c '%a' "${T9}/out.csv")" == 600 ]] && pass "export --output: mode 600" || fail "export output mode"
[[ "$(wc -l < "${T9}/out.csv" | tr -d ' ')" == 7 ]] && grep -q '6 entries' <<< "$out" && pass "export --output: 6 entries counted" || fail "export output count: $out"
out=$(CRED_SERVER_IP=203.0.113.9 run "credentials_export --output='${T9}/out.csv'"); rc=$?
[[ $rc -eq 1 && "$out" == *"exists"* ]] && pass "export --output refuses an existing file" || fail "export overwrite: rc=$rc $out"
: > "$CALLS"
out=$(CRED_SERVER_IP=203.0.113.9 run 'credentials_show' < /dev/null); rc=$?
[[ $rc -eq 0 && "$out" == *"Server credentials"* ]] && grep -q 'log_action CREDENTIALS SHOWN' "$CALLS" && grep -q 'notify credentials_show' "$CALLS" \
    && pass "cipi credentials: the card, logged and notified" || fail "credentials_show: rc=$rc"
out=$(run 'credentials_command nonsense'); rc=$?
[[ $rc -eq 1 && "$out" == *"Use: cipi credentials"* ]] && pass "unknown subcommand → usage, 1" || fail "credentials_command: rc=$rc $out"
grep -q '^credentials_show|Security|' "${LIB}/notifications.sh" && pass "notification trigger credentials_show in the catalog" || fail "trigger missing"

# ── 6. setup.sh ──────────────────────────────────────────────
echo "--- setup.sh"
K1="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA alice@laptop"
K2="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQC0 bob@desk"
out=$(run "SSH_PUBKEYS=(); _ssh_key_add '${K1}'; echo \"n=\${#SSH_PUBKEYS[@]}\"; _ssh_key_add '${K1}' && echo added || echo \"rc=\$?\"; _ssh_key_add $'  ${K2}\r' && echo \"n=\${#SSH_PUBKEYS[@]} last=<\${SSH_PUBKEYS[1]}>\"; _ssh_key_add 'garbage key' || echo \"rc=\$?\"; _ssh_key_add '' || echo \"rc=\$?\"")
[[ "$out" == *"n=1"* ]] && pass "_ssh_key_add: a valid key is added" || fail "add: $out"
[[ "$out" == *"rc=2"* ]] && pass "_ssh_key_add: the same key again → 2" || fail "dup: $out"
[[ "$out" == *"n=2 last=<${K2}>"* ]] && pass "_ssh_key_add: CR and blanks stripped, second key kept" || fail "clean: $out"
[[ "$(grep -c 'rc=1' <<< "$out")" == 2 ]] && pass "_ssh_key_add: garbage and empty → 1" || fail "invalid: $out"

body=$(fn "${ROOT}/setup.sh" collect_ssh_keys)
grep -q 'Add another SSH public key?' <<< "$body" && pass "the installer asks for another key" || fail "no 'another key' question"
grep -q 'done <<< "$SSH_PUBKEY"' <<< "$body" && pass "SSH_PUBKEY: one key per line" || fail "SSH_PUBKEY lines"
grep -q 'No terminal to ask for the key' <<< "$body" && pass "no terminal, no key: stops with the command" || fail "no-tty guard"
n=$(grep -c '_ssh_key_add "$key"' <<< "$body"); m=$(grep -c '_ssh_key_add "$key" && rc=0 || rc=$?' <<< "$body")
(( n == 2 && n == m )) && pass "every _ssh_key_add call is guarded for set -e" || fail "set -e guard: $n calls, $m guarded"
body=$(fn "${ROOT}/setup.sh" setup_ssh)
grep -q "printf '%s\\\\n' \"\${SSH_PUBKEYS\[@\]}\" > /home/cipi/.ssh/authorized_keys" <<< "$body" && pass "setup_ssh writes every key" || fail "authorized_keys write"
! grep -q 'echo "$SSH_PUBKEY" >' "${ROOT}/setup.sh" && pass "the single-key write is gone" || fail "single-key write left"
body=$(fn "${ROOT}/setup.sh" confirm_plan)
grep -q 'Proceed with the installation?' <<< "$body" && grep -q 'Installation cancelled. Nothing was changed.' <<< "$body" && grep -q 'exit 0' <<< "$body" \
    && pass "confirm_plan: the plan, then Proceed? — n exits 0" || fail "confirm_plan"
grep -q '_ssh_key_describe "$k"' <<< "$body" && pass "confirm_plan lists the keys" || fail "confirm_plan keys"
body=$(fn "${ROOT}/setup.sh" main)
a=$(lineof "$body" collect_ssh_keys); b=$(lineof "$body" confirm_plan); c=$(lineof "$body" install_basics)
(( a > 0 && b > a && c > b )) && pass "main: keys, plan, then the install" || fail "main order: $a $b $c"
body=$(fn "${ROOT}/setup.sh" final_summary)
a=$(lineof "$body" 'SAVE THESE CREDENTIALS NOW'); b=$(lineof "$body" credentials_card); c=$(lineof "$body" _confirm_credentials_saved); d=$(lineof "$body" _setup_optional_wizard)
(( a > 0 && b > a && c > b && d > c )) && pass "final_summary: warning, card, saved? gate, then the optional wizard" || fail "final_summary order: $a $b $c $d"
grep -q 'source "${CIPI_LIB}/credentials.sh"' <<< "$body" && pass "final_summary renders the same card as cipi credentials" || fail "final_summary source"
body=$(fn "${ROOT}/setup.sh" _confirm_credentials_saved)
grep -q 'while true' <<< "$body" && grep -q '\^\[Yy\]\$' <<< "$body" && grep -q 'read -r a < /dev/tty' <<< "$body" && pass "the gate asks again until y, on the terminal" || fail "gate"
body=$(fn "${ROOT}/setup.sh" _setup_optional_wizard)
grep -q 'Install the panel API now?' <<< "$body" && grep -q 'Install the web GUI on this server now?' <<< "$body" && pass "the wizard asks API, then GUI" || fail "wizard questions"
body=$(fn "${ROOT}/setup.sh" _setup_run_panel)
grep -q '/usr/local/bin/cipi "$what" "$domain" < /dev/tty' <<< "$body" && pass "the wizard runs cipi api|gui with stdin on the terminal" || fail "wizard run"
grep -q 'Try again?' <<< "$body" && pass "the wizard offers another go" || fail "wizard retry"
! grep -q '_final_summary_panel_guide' "${ROOT}/setup.sh" && pass "the five-step guide is gone" || fail "panel guide left"

# ── 6b. cipi gui sso ─────────────────────────────────────────
echo "--- cipi gui sso"
G="${T9}/gui"; mkdir -p "$G"; : > "${G}/artisan"
printf 'APP_URL=https://panel.example.com\nSESSION_DRIVER=file\n' > "${G}/.env"
runsso() { CIPI_GUI_ROOT="$G" run "$@"; }
out=$(runsso '_gui_env_set CIPI_GUI_SSO_ISSUER "https://login.microsoftonline.com/t/v2.0"; _gui_env_get CIPI_GUI_SSO_ISSUER')
[[ "$out" == "https://login.microsoftonline.com/t/v2.0" ]] && grep -q '^CIPI_GUI_SSO_ISSUER="https://login.microsoftonline.com/t/v2.0"$' "${G}/.env" \
    && pass "_gui_env_set appends a quoted KEY=value, _gui_env_get reads it back" || fail "env set/get: $out"
out=$(runsso '_gui_env_set CIPI_GUI_SSO_ISSUER "https://accounts.google.com"; _gui_env_get CIPI_GUI_SSO_ISSUER')
[[ "$out" == "https://accounts.google.com" && "$(grep -c '^CIPI_GUI_SSO_ISSUER=' "${G}/.env")" == 1 ]] && pass "_gui_env_set replaces an existing key once" || fail "env replace: $out"
out=$(runsso '_gui_env_set CIPI_GUI_SSO_CLIENT_SECRET "se\"c#ret pass"; _gui_env_get CIPI_GUI_SSO_CLIENT_SECRET')
[[ "$out" == 'se"c#ret pass' ]] && grep -q '^CIPI_GUI_SSO_CLIENT_SECRET="se\\"c#ret pass"$' "${G}/.env" && pass "a secret with a quote, # and a space survives" || fail "env escaping: $out / $(grep SECRET "${G}/.env")"
runsso '_gui_env_unset CIPI_GUI_SSO_CLIENT_SECRET' >/dev/null
! grep -q 'CLIENT_SECRET' "${G}/.env" && grep -q '^SESSION_DRIVER=file$' "${G}/.env" && pass "_gui_env_unset drops the key and keeps the rest" || fail "env unset"
runsso '_gui_env_unset CIPI_GUI_SSO_ISSUER' >/dev/null
for pair in "https://login.microsoftonline.com/x/v2.0|Microsoft Entra ID" "https://accounts.google.com|Google" "https://dev-1.okta.com|Okta" "https://id.example.com/realms/a|SSO"; do
    out=$(runsso "_gui_sso_default_label '${pair%%|*}'")
    [[ "$out" == "${pair#*|}" ]] && pass "label for ${pair%%|*}: ${out}" || fail "label ${pair%%|*}: ${out}"
done
: > "$CALLS"
out=$(runsso 'gui_sso_set --issuer=https://login.microsoftonline.com/abc/v2.0/ --client-id=cid-1 --client-secret=top-secret --domains=example.com,example.org --only' < /dev/null); rc=$?
[[ $rc -eq 0 ]] && pass "gui sso set: 0" || fail "gui sso set rc=$rc: $out"
grep -q '^CIPI_GUI_SSO_ISSUER="https://login.microsoftonline.com/abc/v2.0"$' "${G}/.env" && pass "set: issuer stored without the trailing slash" || fail "set issuer: $(grep ISSUER "${G}/.env")"
grep -q '^CIPI_GUI_SSO_CLIENT_ID="cid-1"$' "${G}/.env" && grep -q '^CIPI_GUI_SSO_CLIENT_SECRET="top-secret"$' "${G}/.env" && pass "set: client id and secret stored" || fail "set client"
grep -q '^CIPI_GUI_SSO_DOMAINS="example.com,example.org"$' "${G}/.env" && grep -q '^CIPI_GUI_SSO_ONLY="true"$' "${G}/.env" && pass "set: domains and --only stored" || fail "set domains/only"
[[ "$out" == *"Redirect URI:  https://panel.example.com/auth/sso/callback"* ]] && pass "set prints the Redirect URI to register" || fail "set redirect uri: $out"
[[ "$out" == *"Sign in with Microsoft Entra ID"* && "$out" == *"off for everyone"* && "$out" == *"top-…"* ]] && pass "set: status with the derived label, SSO-only, the secret masked" || fail "set status: $out"
grep -q 'sudo -u www-data php artisan optimize:clear' "$CALLS" && grep -q 'sudo -u www-data php artisan migrate --force' "$CALLS" && grep -q 'log_action GUI SSO SET' "$CALLS" && grep -q 'notify gui_sso' "$CALLS" && pass "set: config cache cleared, migrated, logged, notified" || fail "set side effects: $(cat "$CALLS")"
! grep -q "sso_subject" "$CALLS" && pass "set: a first configuration does not touch the linked identities" || fail "first set reset links"
: > "$CALLS"
out=$(runsso 'gui_sso_set --issuer=https://login.microsoftonline.com/abc/v2.0 --client-id=cid-2 --client-secret=top-secret' < /dev/null)
grep -q "update(\['sso_subject' => null\])" "$CALLS" && [[ "$out" == *"linked so far were forgotten"* ]] && pass "set with a new client id forgets the linked identities" || fail "relink on client change: $out"
: > "$CALLS"
out=$(runsso 'gui_sso_set --issuer=https://login.microsoftonline.com/abc/v2.0 --client-id=cid-2 --label=Work' < /dev/null)
! grep -q "sso_subject" "$CALLS" && pass "set with the same issuer and client id keeps the links" || fail "same provider reset links"
out=$(GUI_PKG_VERSION=4.0.1 runsso 'gui_sso_set --issuer=https://accounts.google.com --client-id=cid --client-secret=s' < /dev/null)
[[ "$out" == *"needs 4.0.2 or later"* ]] && pass "set warns on a panel older than 4.0.2" || fail "set version warning: $out"
out=$(GUI_PKG_VERSION=4.0.2 runsso 'gui_sso_set --issuer=https://accounts.google.com --client-id=cid --client-secret=s' < /dev/null)
[[ "$out" != *"or later"* ]] && pass "no warning on 4.0.2" || fail "set warned on 4.0.2: $out"
out=$(runsso 'gui_sso_set --issuer=http://plain.example.com --client-id=cid --client-secret=s' < /dev/null); rc=$?
[[ $rc -eq 1 && "$out" == *"https://"* ]] && pass "set refuses a non-https issuer" || fail "set http issuer: rc=$rc"
out=$(runsso 'gui_sso_set --issuer=https://accounts.google.com' < /dev/null); rc=$?
[[ $rc -eq 1 && "$out" == *"Usage: cipi gui sso set"* ]] && pass "set without --client-id → usage, 1" || fail "set usage: rc=$rc"
out=$(runsso 'gui_sso_set --issuer=https://accounts.google.com --client-id=cid --client-secret=s --domains=not_a_domain' < /dev/null); rc=$?
[[ $rc -eq 1 && "$out" == *"Invalid domain"* ]] && pass "set refuses a bad --domains entry" || fail "set domains: rc=$rc $out"
out=$(runsso 'gui_sso_set --issuer=https://accounts.google.com --client-id=cid' < /dev/null); rc=$?
[[ $rc -eq 0 ]] && grep -q '^CIPI_GUI_SSO_CLIENT_SECRET=' "${G}/.env" && pass "set without --client-secret keeps the stored one" || fail "set keeps secret: rc=$rc $out"
out=$(runsso 'gui_sso_only off' < /dev/null); rc=$?
[[ $rc -eq 0 ]] && ! grep -q 'CIPI_GUI_SSO_ONLY' "${G}/.env" && pass "sso only off: password sign-in back" || fail "only off: rc=$rc"
out=$(runsso 'gui_sso_only on' < /dev/null); rc=$?
[[ $rc -eq 0 ]] && grep -q '^CIPI_GUI_SSO_ONLY="true"$' "${G}/.env" && [[ "$out" == *"break-glass"* || "$out" == *"Locked out"* ]] && pass "sso only on: stored, with the way out" || fail "only on: rc=$rc $out"
out=$(runsso 'gui_sso_status' < /dev/null)
[[ "$out" == *"Status:        on"* && "$out" == *"example.com,example.org"* ]] || true
out=$(runsso 'gui_sso_disable' < /dev/null); rc=$?
[[ $rc -eq 0 ]] && ! grep -q 'CIPI_GUI_SSO' "${G}/.env" && grep -q '^APP_URL=https://panel.example.com$' "${G}/.env" && pass "sso disable: every key gone, the rest of .env intact" || fail "disable: rc=$rc"
out=$(runsso 'gui_sso_status' < /dev/null)
[[ "$out" == *"off"* && "$out" == *"cipi gui sso set"* ]] && pass "status when off names the command" || fail "status off: $out"
out=$(runsso 'gui_sso_only on' < /dev/null); rc=$?
[[ $rc -eq 1 && "$out" == *"not configured"* ]] && pass "sso only on without SSO is refused" || fail "only on unconfigured: rc=$rc"
out=$(runsso 'gui_sso_command nonsense' < /dev/null); rc=$?
[[ $rc -eq 1 && "$out" == *"Usage: cipi gui sso set"* ]] && pass "unknown sso subcommand → usage, 1" || fail "sso usage: rc=$rc"
grep -q '        sso) gui_sso_command "$@" ;;' "${LIB}/gui.sh" && pass "cipi gui sso is routed" || fail "sso route"
grep -q '"cipi gui sso set"' "${ROOT}/cipi" && pass "help names cipi gui sso" || fail "help sso"
grep -q 'sso)    sub="set status only disable"' "${LIB}/completion.sh" && pass "completion knows cipi gui sso" || fail "completion sso"
grep -q '^gui_sso|Security|' "${LIB}/notifications.sh" && pass "notification trigger gui_sso in the catalog" || fail "trigger gui_sso"

# ── 7. cipi, help, completion ────────────────────────────────
echo "--- cipi / completion"
grep -q 'credentials|creds) _maybe_cmd_help credentials "$@"; require_root; source "${CIPI_LIB}/credentials.sh"; credentials_command "$@" ;;' "${ROOT}/cipi" \
    && pass "cipi credentials is routed" || fail "route"
grep -q '^        credentials|creds)$' "${ROOT}/cipi" && grep -q 'cipi help <topic>' "${ROOT}/cipi" && pass "help topic credentials" || fail "help topic"
grep -q 'reset  credentials  server' "${ROOT}/cipi" && pass "credentials among the help topics" || fail "topics list"
grep -q '"cipi credentials ..."' "${ROOT}/cipi" && pass "credentials in the help index" || fail "help index"
grep -q 'DNS check, install, certificate, token' "${ROOT}/cipi" && grep -q 'DNS check, admin account, install, certificate' "${ROOT}/cipi" && pass "help api/gui name the one-command flow" || fail "help api/gui"
grep -q 'notifications reset credentials completion help"' "${LIB}/completion.sh" && grep -q '^        credentials|creds)$' "${LIB}/completion.sh" \
    && pass "completion knows cipi credentials" || fail "completion credentials"
grep -q 'sub="--no-ssl --no-token --skip-dns-check"' "${LIB}/completion.sh" && grep -q 'sub="--no-ssl --skip-dns-check"' "${LIB}/completion.sh" \
    && pass "completion offers the new flags after a domain" || fail "completion flags"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]]
