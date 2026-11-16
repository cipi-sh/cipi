#!/bin/bash
# Local regression checks for 5.8.6 — app users out of www-data, the stock
# www pool socket 0600, the panel sudoers written only with a panel, root's
# temp directories from mktemp, cipi-app-notify validating its arguments
# (the -eq arithmetic injection) and parse_args refusing an option name that
# is not one (the same injection through `printf -v`). Pure bash + coreutils:
# cipi-app-notify and parse_args are run for real, and so is the migration —
# against a fake root under the temp dir, with getent, gpasswd, systemctl and
# supervisorctl stubbed (that part needs jq and is skipped without it).
# Nothing outside the temp dir is touched and no mail is sent.
# Run from repo root: bash tests/verify-5.8.6.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0

pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
fn() { sed -n "/^${2}() {/,/^}/p" "${LIB}/${1}"; }

TMP=$(mktemp -d) && [[ -n "$TMP" && -d "$TMP" ]] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "${TMP:?}"' EXIT

echo "=== Cipi 5.8.6 regression checks ==="

[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.8.6" ]] \
    && pass "version.md is 5.8.6" || fail "version.md is not 5.8.6"
grep -q '^## \[5.8.6\]' "${ROOT}/CHANGELOG.md" && grep -q 'BASH_VERSINFO' "${ROOT}/CHANGELOG.md" \
    && pass "CHANGELOG has a 5.8.6 entry naming the -eq injection" || fail "CHANGELOG 5.8.6"
for f in app.sh sync.sh php.sh api.sh gui.sh common.sh self-update.sh cipi-app-notify.sh cipi-api-sudoers.sh migrations/5.8.6.sh; do
    bash -n "${LIB}/${f}" && pass "${f} parses" || fail "${f} does not parse"
done
bash -n "${ROOT}/setup.sh" && pass "setup.sh parses" || fail "setup.sh does not parse"

# ── 1. static: app users out of www-data ────────────────────
echo "--- static: www-data membership"
for f in app.sh sync.sh; do
    grep -qE 'useradd .*-G www-data' "${LIB}/${f}" \
        && fail "${f} still adds app users to www-data" || pass "${f}: useradd without www-data"
    grep -qE 'useradd .*-G cipi-apps' "${LIB}/${f}" \
        && pass "${f}: app users still land in cipi-apps" || fail "${f}: cipi-apps membership lost"
    grep -qE 'usermod -aG "\$app(_user)?" www-data' "${LIB}/${f}" \
        && pass "${f}: www-data still joins the app's group (nginx, panel)" || fail "${f}: www-data no longer joins the app group"
done

# ── 2. static: stock www pool socket ────────────────────────
echo "--- static: www pool"
for f in "${ROOT}/setup.sh" "${LIB}/php.sh"; do
    awk '/pool.d\/www.conf" <<POOLEOF/,/^POOLEOF/' "$f" | grep -q '^listen.mode = 0600$' \
        && pass "$(basename "$f"): www pool carries listen.mode = 0600" || fail "$(basename "$f"): www pool without listen.mode = 0600"
done
grep -q 'listen.mode = 0660' "${LIB}/app.sh" \
    && pass "app pools keep listen.mode = 0660 (nginx is in group www-data)" || fail "app pool listen.mode changed"

# ── 3. static: panel sudoers only with a panel ──────────────
echo "--- static: sudoers"
grep -q '^_cipi_panel_installed()' "${LIB}/cipi-api-sudoers.sh" && grep -q '^ensure_cipi_api_sudoers()' "${LIB}/cipi-api-sudoers.sh" \
    && pass "cipi-api-sudoers.sh has the panel check and ensure helper" || fail "sudoers helpers missing"
grep -qE '^[[:space:]]+write_cipi_api_sudoers$' "${ROOT}/setup.sh" \
    && fail "setup.sh still writes the sudoers unconditionally" || pass "setup.sh no longer writes the sudoers on every server"
grep -qE '^[[:space:]]+ensure_cipi_api_sudoers$' "${ROOT}/setup.sh" \
    && pass "setup.sh goes through ensure_cipi_api_sudoers" || fail "setup.sh does not call ensure_cipi_api_sudoers"
fn api.sh api_setup | grep -c '_panel_sudoers_ensure' >/dev/null \
    && pass "cipi api <domain> writes the sudoers" || fail "api_setup does not write the sudoers"
fn gui.sh gui_setup | grep -c '_panel_sudoers_ensure' >/dev/null \
    && pass "cipi gui <domain> writes the sudoers" || fail "gui_setup does not write the sudoers"
fn api.sh api_remove | grep -c '_panel_sudoers_ensure' >/dev/null && fn gui.sh gui_remove | grep -c '_panel_sudoers_ensure' >/dev/null \
    && pass "api/gui remove drop the sudoers with the last panel" || fail "remove paths do not re-evaluate the sudoers"
grep -q '/usr/local/bin/cipi ssh add \*' "${LIB}/cipi-api-sudoers.sh" \
    && pass "the whitelist itself is unchanged (cipi ssh add from the panel still works)" || fail "whitelist content changed"
grep -q '^_panel_sudoers_ensure()' "${LIB}/common.sh" \
    && pass "common.sh has _panel_sudoers_ensure" || fail "_panel_sudoers_ensure missing from common.sh"

# functional: the ensure helper against a fake root (paths rewritten into TMP)
FAKE="${TMP}/root"; mkdir -p "${FAKE}/etc/sudoers.d" "${FAKE}/etc/cipi" "${FAKE}/opt/cipi/api"
sed "s#/etc/sudoers.d/#${FAKE}/etc/sudoers.d/#g; s#/etc/php/#${FAKE}/etc/php/#g; s#/etc/nginx/#${FAKE}/etc/nginx/#g; s#/etc/systemd/#${FAKE}/etc/systemd/#g; s#/etc/cron.d/#${FAKE}/etc/cron.d/#g" \
    "${LIB}/cipi-api-sudoers.sh" > "${TMP}/sudoers.sh"
(
    export CIPI_CONFIG="${FAKE}/etc/cipi" CIPI_API_ROOT="${FAKE}/opt/cipi/api" CIPI_GUI_ROOT="${FAKE}/opt/cipi/gui"
    # shellcheck source=/dev/null
    source "${TMP}/sudoers.sh"
    echo stale > "${FAKE}/etc/sudoers.d/cipi-api"
    ensure_cipi_api_sudoers >/dev/null
    [[ ! -f "${FAKE}/etc/sudoers.d/cipi-api" ]] && echo removed
    touch "${FAKE}/etc/cipi/api.json"
    ensure_cipi_api_sudoers >/dev/null
    grep -q 'cipi ssh add' "${FAKE}/etc/sudoers.d/cipi-api" && echo written
    rm -f "${FAKE}/etc/cipi/api.json"; touch "${FAKE}/opt/cipi/api/artisan"
    _cipi_panel_installed && echo half-installed
) > "${TMP}/sudoers.out" 2>/dev/null
grep -qx removed "${TMP}/sudoers.out" && pass "ensure: no panel → stale sudoers removed" || fail "ensure: stale sudoers kept"
grep -qx written "${TMP}/sudoers.out" && pass "ensure: api.json present → whitelist written" || fail "ensure: whitelist not written with a panel"
grep -qx half-installed "${TMP}/sudoers.out" && pass "panel check: artisan alone counts as installed (keeps the file mid-install)" || fail "panel check misses a half install"

# ── 4. static: mktemp for everything root builds in ─────────
echo "--- static: temp directories"
grep -q 'mktemp -d /tmp/cipi-update.XXXXXXXXXX' "${LIB}/self-update.sh" \
    && pass "self-update clones into a mktemp directory" || fail "self-update temp dir not from mktemp"
grep -qE '^[[:space:]]*local tmp="/tmp/cipi-update-\$\$"' "${LIB}/self-update.sh" \
    && fail "self-update still names /tmp/cipi-update-\$\$" || pass "self-update: no predictable /tmp/cipi-update-\$\$"
grep -q 'installation unchanged' "${LIB}/self-update.sh" \
    && fail "self-update still claims 'installation unchanged' on a failed migration" || pass "self-update: failed-migration message says the files are already in place"
grep -qE '(cd /tmp && composer create-project|rm -rf /tmp/cipi-api-build 2>)' "${LIB}/api.sh" \
    && fail "api.sh still builds in /tmp/cipi-api-build" || pass "api.sh builds in a mktemp directory"
[[ "$(grep -c 'mktemp -d /var/tmp/cipi-api-build.XXXXXXXX' "${LIB}/api.sh")" -eq 2 ]] \
    && pass "api.sh: both build paths (install, upgrade) use mktemp" || fail "api.sh: a build path without mktemp"
grep -q 'mktemp -d /var/tmp/cipi-api-backup.XXXXXXXX' "${LIB}/api.sh" \
    && pass "api upgrade backs .env/tokens up to a mktemp directory" || fail "api upgrade backup dir not from mktemp"
grep -q 'cipi-api-backup-\$(date' "${LIB}/api.sh" \
    && fail "api.sh still uses an epoch-named backup dir" || pass "api.sh: no epoch-named backup dir"
grep -q 'mktemp -d /var/tmp/cipi-gui-build.XXXXXXXX' "${LIB}/gui.sh" && grep -q 'mktemp -d /var/tmp/cipi-gui-backup.XXXXXXXX' "${LIB}/gui.sh" \
    && pass "gui.sh build and backup dirs from mktemp" || fail "gui.sh temp dirs not from mktemp"
fn api.sh api_remove | grep -c '/var/tmp/cipi-api-build.\* /var/tmp/cipi-api-backup.\*' >/dev/null \
    && pass "cipi api remove cleans the new temp names" || fail "api_remove misses the new temp names"

# ── 5. static: migration ────────────────────────────────────
echo "--- static: migration 5.8.6"
M="${LIB}/migrations/5.8.6.sh"
grep -q 'gpasswd -d "\$u" www-data' "$M" && pass "migration removes app users from www-data" || fail "migration: no gpasswd -d"
grep -q 'getent group cipi-apps' "$M" && grep -q "jq -r 'keys\[\]'" "$M" \
    && pass "migration enumerates cipi-apps members and apps.json keys only" || fail "migration enumeration"
grep -qE '"\$u" == "root" \|\| "\$u" == "cipi" \|\| "\$u" == "www-data"' "$M" \
    && pass "migration never touches root, cipi, www-data" || fail "migration lacks the root/cipi/www-data guard"
grep -q 'listen.mode = 0600' "$M" && pass "migration adds listen.mode = 0600 to the www pool" || fail "migration: www pool"
grep -q 'is not the Cipi placeholder' "$M" && pass "migration leaves a hand-edited www.conf alone" || fail "migration rewrites any www.conf"
grep -q '_cipi_panel_installed' "$M" && pass "migration keeps the sudoers where a panel is installed" || fail "migration: sudoers check"
grep -q 'php-fpm\${v}" -t' "$M" && pass "migration tests the FPM config before restarting" || fail "migration restarts FPM untested"
grep -q 'supervisorctl restart' "$M" && pass "migration restarts the apps' supervisor programs" || fail "migration: workers keep the old groups"
grep -q 'supervisorctl restart "\${group}:\*"' "$M" \
    && fail "migration restarts whole groups (it would start workers someone stopped)" || pass "migration restarts only what is running"
grep -q 'env -u SUDO_USER /usr/local/bin/cipi-node-switch "\$u" current' "$M" \
    && pass "migration restarts Node SSR apps blue/green, as root itself" || fail "migration: Node SSR processes keep the old groups"

# ── 6. functional: cipi-app-notify ──────────────────────────
echo "--- functional: cipi-app-notify"
STUB="${TMP}/stublib"; HOME_ROOT="${TMP}/home"; LOGD="${TMP}/log"
mkdir -p "$STUB" "${HOME_ROOT}/myapp/logs" "${HOME_ROOT}/other" "$LOGD"
printf '#!/bin/bash\n' > "${STUB}/vault.sh"
printf '_smtp_send() { printf "SUBJECT=%%s\\n---\\n%%b\\n" "$1" "$2" > "%s/mail.out"; }\n' "$TMP" > "${STUB}/smtp.sh"
: > "${STUB}/notifications.sh"
printf 'secret-of-other\n' > "${HOME_ROOT}/other/.env"
printf 'deploy failed line\n' > "${HOME_ROOT}/myapp/logs/deploy.log"
ln -sf ../../other/.env "${HOME_ROOT}/myapp/logs/evil"
# The script hard-codes /home/<app>; point that at the fixture for the run.
sed "s#/home/\${APP}/#${HOME_ROOT}/\${APP}/#" "${LIB}/cipi-app-notify.sh" > "${TMP}/notify.sh"
notify() {
    rm -f "${TMP}/pwned" "${TMP}/mail.out"
    CIPI_LIB="$STUB" CIPI_CONFIG="${TMP}/cfg" CIPI_LOG="$LOGD" bash "${TMP}/notify.sh" "$@" >/dev/null 2>&1
    echo $?
}

grep -q '"\$EXIT_CODE" -eq' "${LIB}/cipi-app-notify.sh" \
    && fail "notify still compares EXIT_CODE with -eq" || pass "notify: no -eq on the exit code"
grep -q '\[\[ "\$EXIT_CODE" =~ \^\[0-9\]{1,3}\$ \]\] || exit 2' "${LIB}/cipi-app-notify.sh" \
    && pass "notify: exit code must be 1-3 digits" || fail "notify: exit code not validated"

rc=$(notify myapp deploy "BASH_VERSINFO[\$(touch ${TMP}/pwned)]")
[[ "$rc" == "2" && ! -e "${TMP}/pwned" ]] \
    && pass "PoC 'BASH_VERSINFO[\$(cmd)]' is refused (exit 2) and the command does not run" || fail "PoC: rc=${rc}, pwned=$([[ -e "${TMP}/pwned" ]] && echo yes || echo no)"
rc=$(notify myapp $'deploy\nBcc: x@example.com' 1)
[[ "$rc" == "2" ]] && pass "a label with a newline (header injection) is refused" || fail "label injection accepted (rc=${rc})"
rc=$(notify 'My App' deploy 1)
[[ "$rc" == "2" ]] && pass "an app name that is not app-shaped is refused" || fail "bad app name accepted"
rc=$(notify myapp deploy 0)
[[ "$rc" == "0" && ! -f "${TMP}/mail.out" ]] && pass "exit code 0 → silent, no mail" || fail "exit 0 sent a mail or failed (rc=${rc})"
rc=$(notify myapp deploy 1 "${HOME_ROOT}/myapp/logs/deploy.log" "Trigger: webhook")
[[ "$rc" == "0" ]] && grep -q 'deploy failed line' "${TMP}/mail.out" && grep -q 'Trigger: webhook' "${TMP}/mail.out" \
    && pass "a real failure mails the app's own log tail and the detail block" || fail "legitimate failure path broken (rc=${rc})"
grep -q 'Cipi deploy failed: myapp' "${LOGD}/events.log" && pass "events.log records the failure" || fail "events.log not written"
rc=$(notify myapp deploy 1 "${HOME_ROOT}/myapp/logs/evil")
[[ "$rc" == "0" ]] && ! grep -q 'secret-of-other' "${TMP}/mail.out" && grep -q '<no output>' "${TMP}/mail.out" \
    && pass "a symlink out of the app's home is read as 'no log', the mail still goes" || fail "symlink escape leaked or notification dropped"
rc=$(notify myapp deploy 1 "${HOME_ROOT}/other/.env")
[[ "$rc" == "0" ]] && ! grep -q 'secret-of-other' "${TMP}/mail.out" \
    && pass "a path outside the app's home is not read" || fail "foreign path read as root"
rc=$(notify myapp deploy-ok 0 "${HOME_ROOT}/myapp/logs/deploy.log" "Release: 1 -> 2")
[[ "$rc" == "0" ]] && grep -q 'deploy succeeded: myapp' "${TMP}/mail.out" \
    && pass "deploy-ok (success mail) path unchanged" || fail "deploy-ok path broken (rc=${rc})"
rc=$(notify myapp deploy 1 "" "$(printf 'Trigger: x\033[31mred\007')")
[[ "$rc" == "0" ]] && ! grep -q $'\033' "${TMP}/mail.out" && ! grep -q $'\007' "${TMP}/mail.out" && grep -q 'Trigger: x\[31mred' "${TMP}/mail.out" \
    && pass "control characters are stripped from the free text" || fail "control characters reached the mail"
rc=$(SUDO_USER=otherapp notify myapp deploy 1)
[[ "$rc" == "2" ]] && pass "called through sudo by another user → refused" || fail "SUDO_USER mismatch accepted (rc=${rc})"
rc=$(SUDO_USER=myapp notify myapp deploy 1)
[[ "$rc" == "0" ]] && pass "called through sudo by the app's own user → accepted" || fail "own user refused (rc=${rc})"

# ── 7. functional: parse_args ───────────────────────────────
# Every `cipi` command parses its arguments here as root, and an app user
# with `cipi yml auto` on may pass arguments: `cipi yml node-sync <app> *`.
echo "--- functional: parse_args"
fn common.sh parse_args > "${TMP}/parse_args.sh"
[[ -s "${TMP}/parse_args.sh" ]] && pass "parse_args extracted from common.sh" || fail "parse_args not found in common.sh"
pa() {
    rm -f "${TMP}/pwned"
    bash -c 'set -euo pipefail; source "$1"; shift; parse_args "$@"
             printf "%s|%s|%s|%s|%s|%s\n" "${ARG_finalize:-}" "${ARG_per_page:-}" "${ARG_301:-}" "${ARG_set:-}" "${ARG_name:-}" "${ARG_x:-}"' \
        _ "${TMP}/parse_args.sh" "$@" 2>&1
}
out=$(pa --finalize "--x[\$(touch ${TMP}/pwned)]")
[[ ! -e "${TMP}/pwned" && "$out" == "true|||||" ]] \
    && pass "PoC '--x[\$(cmd)]' is ignored and the command does not run" || fail "PoC flag: out=${out}, pwned=$([[ -e "${TMP}/pwned" ]] && echo yes || echo no)"
out=$(pa "--x[\$(touch ${TMP}/pwned)]=1" --finalize)
[[ ! -e "${TMP}/pwned" && "$out" == "true|||||" ]] \
    && pass "PoC '--x[\$(cmd)]=value' is ignored and the command does not run" || fail "PoC key=value: out=${out}, pwned=$([[ -e "${TMP}/pwned" ]] && echo yes || echo no)"
out=$(pa '--a b=1' '--=1' '--' '--x.y=1' "--x;touch ${TMP}/pwned" --finalize)
[[ ! -e "${TMP}/pwned" && "$out" == "true|||||" ]] \
    && pass "names with spaces, dots, separators or no name at all are not options" || fail "odd option names: out=${out}"
out=$(pa --finalize --per-page=20 --301 --set=APP_KEY=a=b "--name='with space'" --x=1)
[[ "$out" == "true|20|true|APP_KEY=a=b|with space|1" ]] \
    && pass "real options parse as before (flags, key=value, numeric names, values with =, quoted values)" || fail "legitimate options broken: ${out}"
out=$(pa "--x=\$(touch ${TMP}/pwned)" "--name=a[\$(touch ${TMP}/pwned)]")
[[ ! -e "${TMP}/pwned" && "$out" == "||||a[\$(touch ${TMP}/pwned)]|\$(touch ${TMP}/pwned)" ]] \
    && pass "values are stored as text, never evaluated" || fail "a value was evaluated: ${out}"

# ── 8. functional: migration 5.8.6 against a fake root ──────
echo "--- functional: migration 5.8.6 (fake root)"
if ! command -v jq >/dev/null 2>&1; then
    echo "  SKIP: jq not installed — migration dry run not executed"
else
    R="${TMP}/root"
    mkdir -p "$R"/{lib,bin,cfg,log,etc/php/8.3/fpm/pool.d,etc/supervisor/conf.d,etc/sudoers.d,var/lib/cipi/node,run/lock,home/nodeapp/releases/7,home/staticnode}
    cp "${LIB}"/*.sh "$R/lib/"
    cp "$M" "$R/migration.sh"
    # Absolute paths → the fake root.
    sed -i -e "s#/etc/php/#$R/etc/php/#g" -e "s#/etc/supervisor/conf.d/#$R/etc/supervisor/conf.d/#g" \
        -e "s#/var/lib/cipi/node/#$R/var/lib/cipi/node/#g" -e "s#\"/home/\${u}/current\"#\"$R/home/\${u}/current\"#g" \
        -e "s#/run/lock/#$R/run/lock/#g" -e "s#/usr/local/bin/cipi-node-switch#$R/bin/cipi-node-switch#g" \
        -e "s#/etc/sudoers.d/cipi-api#$R/etc/sudoers.d/cipi-api#g" -e "s#/etc/nginx/sites-available/#$R/etc/nginx/sites-available/#g" \
        -e "s#/etc/systemd/system/cipi-queue.service#$R/etc/systemd/system/cipi-queue.service#g" -e "s#/etc/cron.d/cipi-#$R/etc/cron.d/cipi-#g" \
        "$R/migration.sh" "$R/lib/cipi-api-sudoers.sh"

    # Four apps (one not in www-data, one Node SSR, one Node static), an app
    # with a reserved name, and an account that is in www-data and not an app.
    echo '{"appa":{},"appb":{},"nodeapp":{},"staticnode":{},"admin":{}}' > "$R/cfg/apps.json"
    printf 'cipi-apps:x:1001:appa,appb,nodeapp,staticnode\n' > "$R/group.cipi-apps"
    printf 'www-data:x:33:appa,nodeapp,staticnode,admin,sysuser\n' > "$R/group.www-data"
    printf '[www]\nuser = www-data\ngroup = www-data\nlisten = /run/php/php8.3-fpm.sock\nlisten.owner = www-data\nlisten.group = www-data\npm = ondemand\n' \
        > "$R/etc/php/8.3/fpm/pool.d/www.conf"
    printf '[program:appa-worker-default]\ncommand=x\n[program:appa-horizon]\ncommand=y\n' > "$R/etc/supervisor/conf.d/appa.conf"
    : > "$R/etc/supervisor/conf.d/nodeapp-node.conf"; : > "$R/etc/supervisor/conf.d/staticnode-node.conf"
    echo '{"mode":"ssr","active":0}' > "$R/var/lib/cipi/node/nodeapp.json"
    echo '{"mode":"static"}' > "$R/var/lib/cipi/node/staticnode.json"
    ln -s releases/7 "$R/home/nodeapp/current"; ln -s . "$R/home/staticnode/current"
    echo 'www-data ALL=(root) NOPASSWD: /usr/local/bin/cipi ssh add *' > "$R/etc/sudoers.d/cipi-api"

    stub() { printf '#!/bin/bash\n%s\n' "$2" > "$R/bin/$1"; chmod +x "$R/bin/$1"; }
    stub getent  "f=\"$R/group.\$2\"; [[ \"\$1\" == group && -f \"\$f\" ]] && cat \"\$f\" || exit 2"
    stub id      'case "${@: -1}" in appa|appb|nodeapp|staticnode|admin|sysuser|root|cipi|www-data) exit 0;; *) exit 1;; esac'
    stub gpasswd "echo \"gpasswd \$*\" >> \"$R/calls\"; [[ \"\$1\" == -d ]] && sed -i -E \"s/(:|,)\$2(,|\\\$)/\\\\1\\\\2/; s/,\\\$//; s/:,/:/\" \"$R/group.\$3\""
    stub dpkg    '[[ "$2" == php8.3-fpm ]]'
    stub systemctl "echo \"systemctl \$*\" >> \"$R/calls\"; exit 0"
    stub php-fpm8.3 'exit 0'
    stub supervisorctl "echo \"supervisorctl \$*\" >> \"$R/calls\"
case \"\$1 \$2\" in
  'status appa-worker-default:*') printf 'appa-worker-default:appa-worker-default_00   RUNNING   pid 11, uptime 1:00:00\nappa-worker-default:appa-worker-default_01   RUNNING   pid 12, uptime 1:00:00\n';;
  'status appa-horizon:*')        printf 'appa-horizon                     STOPPED   Not started\n'; exit 3;;
  status*) echo \"\$2: ERROR (no such group)\"; exit 4;;
esac"
    stub cipi-node-switch "echo \"node-switch \$* SUDO_USER=\${SUDO_USER:-unset}\" >> \"$R/calls\"; exit \${NODE_SWITCH_RC:-0}"

    migrate() {
        : > "$R/calls"
        ( cd "$R" && PATH="$R/bin:$PATH" CIPI_LIB="$R/lib" CIPI_CONFIG="$R/cfg" CIPI_LOG="$R/log" \
            CIPI_API_ROOT="$R/opt/api" CIPI_GUI_ROOT="$R/opt/gui" SUDO_USER=cipi bash "$R/migration.sh" ) > "$R/out" 2>&1
    }

    migrate; rc=$?
    [[ "$rc" -eq 0 ]] && grep -q 'Migration 5.8.6 complete' "$R/out" && pass "migration runs to the end (exit 0)" || { fail "migration aborted (rc=${rc})"; sed 's/^/    /' "$R/out" >&2; }
    [[ "$(grep -c '^gpasswd -d' "$R/calls")" -eq 3 ]] && grep -q '^gpasswd -d appa www-data$' "$R/calls" \
        && grep -q '^gpasswd -d nodeapp www-data$' "$R/calls" && grep -q '^gpasswd -d staticnode www-data$' "$R/calls" \
        && pass "the three app users in www-data are removed, and only they" || fail "wrong gpasswd calls: $(tr '\n' ';' < "$R/calls")"
    [[ "$(cut -d: -f4 "$R/group.www-data")" == "admin,sysuser" ]] \
        && pass "an account that is not an app stays in www-data" || fail "www-data members after: $(cat "$R/group.www-data")"
    grep -q 'WARNING: admin: listed as an app but not an app-shaped name' "$R/out" \
        && pass "an app with a reserved name is reported, not skipped in silence" || fail "reserved-name app skipped without a word"
    grep -q '^listen.mode = 0600$' "$R/etc/php/8.3/fpm/pool.d/www.conf" && pass "www pool gets listen.mode = 0600" || fail "www.conf not updated"
    [[ ! -e "$R/etc/sudoers.d/cipi-api" ]] && pass "panel sudoers removed on a server with no panel" || fail "panel sudoers left behind"
    grep -q '^systemctl restart php8.3-fpm$' "$R/calls" && pass "PHP-FPM restarted" || fail "PHP-FPM not restarted"
    grep -q '^supervisorctl restart appa-worker-default:appa-worker-default_00$' "$R/calls" \
        && grep -q '^supervisorctl restart appa-worker-default:appa-worker-default_01$' "$R/calls" \
        && pass "running workers are restarted" || fail "running workers not restarted"
    grep -q '^supervisorctl restart appa-horizon' "$R/calls" \
        && fail "a stopped program was started by the migration" || pass "a stopped program stays stopped"
    [[ "$(grep -c '^node-switch' "$R/calls")" -eq 1 ]] && grep -q '^node-switch nodeapp current SUDO_USER=unset$' "$R/calls" \
        && pass "the Node SSR app is switched blue/green, without the caller's SUDO_USER; the static one is left alone" \
        || fail "node switch calls: $(grep '^node-switch' "$R/calls" | tr '\n' ';')"

    migrate; rc=$?
    [[ "$rc" -eq 0 && ! -s "$R/calls" ]] && grep -q 'No app user in www-data' "$R/out" \
        && pass "second run changes nothing (idempotent)" || fail "second run: rc=${rc}, calls=$(tr '\n' ';' < "$R/calls")"

    # A Node process that does not come up, and a panel that is installed.
    printf 'www-data:x:33:nodeapp\n' > "$R/group.www-data"
    echo '{"domain":"panel.example.com"}' > "$R/cfg/api.json"
    echo 'kept' > "$R/etc/sudoers.d/cipi-api"
    NODE_SWITCH_RC=1 migrate; rc=$?
    [[ "$rc" -eq 0 ]] && grep -q 'WARNING: nodeapp: Node process not restarted' "$R/out" \
        && pass "a Node switch that fails is a warning, not an aborted migration" || fail "failed node switch: rc=${rc}"
    [[ "$(cat "$R/etc/sudoers.d/cipi-api" 2>/dev/null)" == "kept" ]] \
        && pass "panel sudoers untouched where a panel is installed" || fail "panel sudoers changed on a server with a panel"
fi

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
