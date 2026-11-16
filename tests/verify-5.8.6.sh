#!/bin/bash
# Local regression checks for 5.8.6 — app users out of www-data, the stock
# www pool socket 0600, the panel sudoers written only with a panel, root's
# temp directories from mktemp, cipi-app-notify validating its arguments
# (the -eq arithmetic injection), parse_args refusing an option name that
# is not one (the same injection through `printf -v`), the logs root writes
# for an app moved out of the app's home (/var/log/cipi-apps/<app>), the log
# readers dropping to the app user, `cipi node restart` under sudo, the swap
# line of root's crontab, the SSH default of a new server, and root no longer
# writing, reading or chowning by path inside an existing app's home (the
# app_as helpers, the .env functions that take a value as data, the sync
# .env merge, the integrity hashing, the Laravel recipe under set -e); and
# the second half of the release: logrotate rules per app (su), cipi pending
# / autoupdate / reboot, one Valkey per app, the panel's trees worked on as
# www-data, the sshd section that gives the server's keys to app users,
# full-access API tokens, the deploy lock released on failure.
# Pure bash + coreutils: cipi-app-notify, parse_args, the log helpers and
# cipi-read-app-logs are run for real, and so is the migration — against a
# fake root under the temp dir, with every command that would act on the
# machine (getent, id, gpasswd, systemctl, supervisorctl, nginx, php-fpm,
# sudo, install, chown, crontab, cipi-node-switch) stubbed; that part needs
# jq and is skipped without it. It covers the move going well, a second
# run, and nginx, supervisor or PHP-FPM refusing the new configuration.
# What needs real accounts — root following, or not, a symlink an app user
# planted, and a function handed to the app user (app_call) on a real home —
# is not here: it was run by hand for the release (CHANGELOG). Here the app
# is a directory and sudo a stub that runs the command as whoever runs the test.
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

# ── 8. static: what root writes for an app is not in the app's home ──
echo "--- static: app logs in /var/log/cipi-apps"
[[ "$(grep -c 'access_log /var/log/cipi-apps/\${app}/nginx-access.log;' "${LIB}/app.sh")" -eq 6 \
   && "$(grep -c 'access_log /var/log/cipi-apps/\${app}/nginx-access.log;' "${LIB}/node.sh")" -eq 2 ]] \
    && pass "every vhost template (6 PHP, 2 Node) logs to /var/log/cipi-apps/<app>" || fail "a vhost template does not log to /var/log/cipi-apps"
grep -qE '(access_log|error_log) /home/' "${LIB}/app.sh" "${LIB}/node.sh" \
    && fail "a vhost template still logs under /home" || pass "no vhost template logs under /home"
grep -q 'stdout_logfile=/home/\|stdout_logfile=\${HOME_DIR}/logs' "${LIB}/common.sh" "${LIB}/cipi-node-switch.sh" \
    && fail "a supervisor program still logs under the app's home" || pass "no supervisor program logs under the app's home"
[[ "$(grep -c 'stdout_logfile=/var/log/cipi-apps/\${app}/' "${LIB}/common.sh")" -ge 4 ]] && grep -q 'stdout_logfile=\${LOG_DIR}/node-' "${LIB}/cipi-node-switch.sh" \
    && pass "workers, octane, reverb, horizon and the Node slots log to /var/log/cipi-apps/<app>" || fail "supervisor log paths"
fn deploy.sh deploy_log_file >/dev/null; grep -q '^deploy_log_file() { echo "/var/log/cipi-apps/\${1:-}/deploy.log"; }' "${LIB}/deploy.sh" \
    && pass "cipi deploy (root) writes deploy.log in /var/log/cipi-apps/<app>" || fail "deploy_log_file still under the app's home"
grep -qF 'php_admin_value[open_basedir] = /home/${app}/:/var/log/cipi-apps/${app}/:/tmp/:/proc/' "${LIB}/app.sh" \
    && pass "the app's pool may read its own log directory (open_basedir)" || fail "pool open_basedir lacks /var/log/cipi-apps/<app>"
fn common.sh ensure_app_logs_permissions | grep -qE 'chmod 2775|^[[:space:]]*mkdir -p "\$\{home\}/logs"|chown "\$\{app\}:www-data" "\$\{home\}/logs"' \
    && fail "ensure_app_logs_permissions still runs mkdir/chown/chmod as root on ~/logs" || pass "root no longer runs mkdir, a plain chown or chmod on ~/logs"
[[ "$(fn common.sh ensure_app_permissions | sed '/_app_as "\$app" /,$d' | grep -vE '^[[:space:]]*#' | grep -c 'chmod')" -eq 1 ]] \
    && fn common.sh ensure_app_permissions | sed -n '/_app_as "\$app" /,$p' | grep -q 'chmod 600' \
    && pass "ensure_app_permissions: root chmods the home itself, everything inside is done as the app user" || fail "ensure_app_permissions still chmods files of the home as root"
fn common.sh ensure_app_permissions | grep -q 'chown -h -R "\${app}:\${app}" "\$home"' \
    && ! fn common.sh ensure_app_logs_permissions | grep -vE '^[[:space:]]*#' | grep -q 'find .* -exec chown' \
    && pass "ensure_app_permissions: ownership through chown -h -R (no symlink followed)" || fail "ensure_app_permissions: chown may follow a symlink"
grep -q 'exec sudo -u "\$app" /bin/bash -c' "${LIB}/cipi-read-app-logs.sh" \
    && pass "cipi-read-app-logs reads as the app user" || fail "cipi-read-app-logs still reads as root"
fn app.sh _cipi_emit_log_page | grep -q 'sudo -u "\$app"' && fn app.sh _app_logs_follow | grep -q 'sudo -u "\$app"' \
    && pass "cipi app logs reads as the app user" || fail "cipi app logs still reads as root"
grep -q '/var/log/cipi-apps/\*/nginx-access.log' "${ROOT}/setup.sh" && grep -q '/var/log/cipi-apps/\*/worker-\*.log' "${ROOT}/setup.sh" \
    && ! grep -qE '^/home/\*/logs/(nginx-|worker-|deploy)' "${ROOT}/setup.sh" \
    && pass "setup.sh: logrotate follows the logs to /var/log/cipi-apps" || fail "setup.sh logrotate paths"
grep -q 'app_logs_relocate --fpm=defer' "$M" && fn app.sh app_fix_permissions | grep -q 'app_logs_relocate' \
    && pass "the move runs in migration 5.8.6 and again from cipi app fix-permissions" || fail "app_logs_relocate not wired in"
bash -n "${LIB}/app-logs.sh" && bash -n "${LIB}/cipi-read-app-logs.sh" && bash -n "${LIB}/cipi-node-switch.sh" && bash -n "${LIB}/node.sh" && bash -n "${LIB}/deploy.sh" \
    && pass "app-logs.sh, cipi-read-app-logs.sh, cipi-node-switch.sh, node.sh, deploy.sh parse" || fail "a changed script does not parse"

# ── 9. static + functional: the rest of this release ────────
echo "--- node restart under sudo, swap cron, SSH default, temp dirs"
grep -q '^_node_switch() { env -u SUDO_USER /usr/local/bin/cipi-node-switch "\$@"; }' "${LIB}/node.sh" \
    && [[ "$(grep -vE '^[[:space:]]*#' "${LIB}/node.sh" | grep -c '/usr/local/bin/cipi-node-switch')" -eq 1 ]] \
    && pass "node.sh calls cipi-node-switch only through _node_switch (SUDO_USER dropped)" || fail "node.sh still calls cipi-node-switch with the caller's SUDO_USER"
cat > "${TMP}/switch-stub" <<'STUB'
#!/bin/bash
echo "SUDO_USER=${SUDO_USER:-unset} args=$*"
STUB
chmod +x "${TMP}/switch-stub"
out=$(SUDO_USER=cipi bash -c "$(fn node.sh _node_switch | sed "s#/usr/local/bin/cipi-node-switch#${TMP}/switch-stub#"); _node_switch myapp current")
[[ "$out" == "SUDO_USER=unset args=myapp current" ]] && pass "_node_switch: the switch does not see the sudo caller" || fail "_node_switch passed: ${out}"
if [[ "$(id -u)" -eq 0 ]]; then
    out=$(SUDO_USER=cipi bash "${LIB}/cipi-node-switch.sh" myapp current 2>&1; echo "rc=$?")
    grep -q 'cipi cannot manage myapp' <<< "$out" \
        && pass "…which it refuses (what sudo cipi node restart ran into before)" || fail "cipi-node-switch accepted a foreign SUDO_USER: ${out}"
else
    grep -q 'cannot manage \${APP}' "${LIB}/cipi-node-switch.sh" \
        && pass "…which it refuses (read from the script: running it needs root)" || fail "cipi-node-switch no longer checks SUDO_USER"
fi

cronline=$(grep -F 'swapoff -a && swapon -a' "${ROOT}/setup.sh" | grep -F '/proc/meminfo' | head -1)
[[ -n "$cronline" ]] && pass "setup.sh: the swap reset checks /proc/meminfo first" || fail "setup.sh: swapoff -a without a memory check"
grep -q "^50 5 \* \* \* echo 3 > /proc/sys/vm/drop_caches && swapoff -a && swapon -a" "${ROOT}/setup.sh" \
    && fail "setup.sh still installs the unguarded swap line" || pass "setup.sh: no unguarded swapoff -a"
guard=$(sed -n "s/.*\(awk '[^']*'\) \/proc\/meminfo.*/\1/p" <<< "$cronline")
swap_ok() { printf 'MemAvailable: %s kB\nSwapTotal: %s kB\nSwapFree: %s kB\n' "$1" "$2" "$3" > "${TMP}/meminfo"; eval "$guard \"${TMP}/meminfo\""; }
if [[ -n "$guard" ]]; then
    swap_ok 4000000 2000000 1500000 && pass "swap guard: 500 MB in swap, 4 GB available → swap is emptied" || fail "swap guard refuses a safe reset"
    swap_ok 800000 2000000 1500000 && fail "swap guard: 500 MB in swap, 800 MB available → should not run swapoff" || pass "swap guard: not enough RAM for twice the swap in use → swapoff is skipped"
    swap_ok 4000000 2000000 2000000 && fail "swap guard: nothing in swap → should not run swapoff" || pass "swap guard: nothing in swap → skipped"
    swap_ok 4000000 0 0 && fail "swap guard: no swap at all → should not run swapoff" || pass "swap guard: no swap configured → skipped"
else
    fail "swap guard: could not read the awk program out of setup.sh"
fi
grep -q 'awk' <<< "$(grep -n 'swapoff -a' "$M")" && grep -q 'crontab -' "$M" \
    && pass "migration rewrites the swap line of root's crontab" || fail "migration leaves the old swap line"

grep -q 'app_ssh_default: "disabled"' "${ROOT}/setup.sh" && grep -q 'fresh_server' "${ROOT}/setup.sh" \
    && pass "setup.sh: a new server starts with SSH/SFTP for app users closed from outside" || fail "setup.sh: no app_ssh_default on a new server"
grep -q 'app_ssh_default' "$M" \
    && fail "migration changes app SSH access on existing servers" || pass "migration does not touch app SSH access on existing servers"

grep -q 'mktemp -d /tmp/cipi-gui-pkg.XXXXXXXXXX' "${LIB}/gui.sh" && ! grep -vE '^[[:space:]]*#' "${LIB}/gui.sh" | grep -q 'cipi-gui-pkg-\$\$' \
    && pass "gui.sh: the path-package copy goes into a mktemp directory" || fail "gui.sh still uses /tmp/cipi-gui-pkg-\$\$"
grep -q 'mktemp -d /tmp/cipi-sync.XXXXXXXXXX' "${LIB}/sync.sh" && ! grep -qE 'tmp="/tmp/cipi-sync-\$\{?ts' "${LIB}/sync.sh" \
    && pass "sync export stages its files in a mktemp directory, mode 700" || fail "sync export still stages in /tmp/cipi-sync-<time>"

# ── 10. functional: helpers and the log reader ──────────────
echo "--- functional: log links and cipi-read-app-logs"
H="${TMP}/h"; V="${TMP}/v"; SB="${TMP}/sbin"; mkdir -p "$H/demo/logs" "$H/demo/shared/storage/logs" "$V" "$SB"
printf '#!/bin/bash\n[[ "$1" == -u ]] && { echo "$2" >> "%s/sudo-users"; shift 2; }\nexec "$@"\n' "$TMP" > "$SB/sudo"
printf '#!/bin/bash\ncase "$1" in -gn) echo "$2";; esac\ncase "${@: -1}" in demo) exit 0;; *) exit 1;; esac\n' > "$SB/id"
chmod +x "$SB/sudo" "$SB/id"
links() {   # app_log_links, on the fake home
    PATH="$SB:$PATH" bash -c "$(fn common.sh _app_as; fn common.sh app_log_links | sed "s#/var/log/cipi-apps/#${V}/#; s#\"/home/\${app}/logs\"#\"${H}/\${app}/logs\"#"); app_log_links \"\$@\"" _ "$@"
}
echo "old lines" > "$H/demo/logs/nginx-access.log"; ln -s /etc/hostname "$H/demo/logs/worker-default.log"; ln -s "$V/demo/deploy.log" "$H/demo/logs/deploy.log"
links demo nginx-access.log worker-default.log deploy.log '../evil' 'a/b'
[[ "$(readlink "$H/demo/logs/nginx-access.log")" == "$V/demo/nginx-access.log" && "$(cat "$H/demo/logs/nginx-access.log.old")" == "old lines" ]] \
    && pass "app_log_links: a regular log becomes <name>.old, the name a symlink to root's directory" || fail "app_log_links: regular file"
[[ "$(readlink "$H/demo/logs/worker-default.log")" == "$V/demo/worker-default.log" && ! -e "$H/demo/logs/worker-default.log.old" ]] \
    && pass "app_log_links: a symlink that points elsewhere is replaced" || fail "app_log_links: foreign symlink"
[[ "$(readlink "$H/demo/logs/deploy.log")" == "$V/demo/deploy.log" && "$(ls "$H/demo/logs" | wc -l)" -eq 4 && ! -e "$H/demo/evil" ]] \
    && pass "app_log_links: a link already right is left; names that are not plain file names are skipped" || fail "app_log_links: $(ls "$H/demo/logs" | tr '\n' ' ')"
grep -qx demo "${TMP}/sudo-users" && pass "app_log_links works as the app user (sudo -u), not as root" || fail "app_log_links did not drop to the app user"

sed "s#\^/home/#^${H}/#" "${LIB}/cipi-read-app-logs.sh" > "${TMP}/read.sh"
rd() { ( PATH="$SB:$PATH" bash "${TMP}/read.sh" "$@" ) 2>/dev/null; }
for i in $(seq 1 25); do echo "line $i"; done > "$H/demo/shared/storage/logs/laravel.log"
: > "${TMP}/sudo-users"
out=$(rd "$H/demo/shared/storage/logs/laravel.log" 2 10); rc=$?
[[ "$rc" -eq 0 && "$(sed -n 1p <<< "$out")" == "===CIPI_LOG_FILE:$H/demo/shared/storage/logs/laravel.log:25===" && "$(sed -n 2p <<< "$out")" == "line 6" \
   && "$(sed -n 11p <<< "$out")" == "line 15" && "$(sed -n 12p <<< "$out")" == "===CIPI_LOG_END===" ]] \
    && pass "cipi-read-app-logs: same pages and markers as before" || fail "cipi-read-app-logs output changed: rc=${rc} $(head -3 <<< "$out" | tr '\n' '|')"
grep -qx demo "${TMP}/sudo-users" && pass "cipi-read-app-logs reads through sudo -u <app>" || fail "cipi-read-app-logs did not drop to the app user"
out=$(rd "$H/demo/logs/../../../etc/hostname" 1 50); rc=$?
[[ "$rc" -ne 0 && -z "$out" ]] && pass "cipi-read-app-logs refuses '..' in the pattern (it printed any file before)" || fail "cipi-read-app-logs followed '..': rc=${rc}"
out=$(rd "$H/demo/logs/x.log /etc/hostname" 1 50); rc=$?
[[ "$rc" -ne 0 && -z "$out" ]] && pass "cipi-read-app-logs refuses a second path after a space" || fail "cipi-read-app-logs took two paths: rc=${rc}"
rd "/etc/hostname" 1 50 >/dev/null; [[ $? -ne 0 ]] && pass "cipi-read-app-logs refuses a path outside an app's log directories" || fail "cipi-read-app-logs read /etc/hostname"
rd "$H/demo/logs/nginx-access.log" 1 '5; id' >/dev/null; [[ $? -ne 0 ]] && pass "cipi-read-app-logs refuses a page size that is not a number" || fail "cipi-read-app-logs took a non-numeric page size"
rd "$H/nouser/logs/x.log" 1 5 >/dev/null; [[ $? -ne 0 ]] && pass "cipi-read-app-logs refuses a home with no such user" || fail "cipi-read-app-logs ran for a user that does not exist"

# ── 11. functional: migration 5.8.6 against a fake root ─────
echo "--- functional: migration 5.8.6 (fake root)"
if ! command -v jq >/dev/null 2>&1; then
    echo "  SKIP: jq not installed — migration dry run not executed"
else
    R="${TMP}/root"
    # A server as 5.8.5 left it, under $R. Every absolute path the migration and
    # its helpers name is rewritten to $R (in two passes, so a temp dir whose own
    # path contains /home/ or /etc/ is not rewritten twice) and every command
    # that would act on the machine is a stub in $R/bin that logs to $R/calls.
    build_root() {
        rm -rf "$R"
        mkdir -p "$R"/{lib,bin,cfg,log,etc/php/8.3/fpm/pool.d,etc/php/8.4/fpm/pool.d,etc/supervisor/conf.d,etc/sudoers.d,etc/nginx/sites-available,etc/nginx/conf.d,etc/logrotate.d,etc/crowdsec/acquis.d,var/lib/cipi/node,var/log,run/lock,home/nodeapp/releases/7,home/staticnode}
        cp "${LIB}"/*.sh "$R/lib/"
        cp "$M" "$R/migration.sh"
        local files=("$R/migration.sh" "$R/lib/app-logs.sh" "$R/lib/common.sh" "$R/lib/cipi-api-sudoers.sh")
        sed -i -e "s#/etc/php/#@@R@@/etc/php/#g" -e "s#/etc/supervisor/conf.d/#@@R@@/etc/supervisor/conf.d/#g" \
            -e "s#/etc/nginx/#@@R@@/etc/nginx/#g" -e "s#/etc/logrotate.d/#@@R@@/etc/logrotate.d/#g" -e "s#/etc/crowdsec/#@@R@@/etc/crowdsec/#g" \
            -e "s#/var/lib/cipi/#@@R@@/var/lib/cipi/#g" -e "s#/var/log/cipi-apps#@@R@@/var/log/cipi-apps#g" \
            -e "s#/home/#@@R@@/home/#g" -e "s#/run/lock/#@@R@@/run/lock/#g" -e "s#/usr/local/bin/cipi-node-switch#@@R@@/bin/cipi-node-switch#g" \
            -e "s#/etc/sudoers.d/cipi-api#@@R@@/etc/sudoers.d/cipi-api#g" -e "s#/etc/systemd/system/cipi-queue.service#@@R@@/etc/systemd/system/cipi-queue.service#g" \
            -e "s#/etc/cron.d/cipi-#@@R@@/etc/cron.d/cipi-#g" "${files[@]}"
        sed -i "s#@@R@@#$R#g" "${files[@]}"

        stub() { printf '#!/bin/bash\n%s\n' "$2" > "$R/bin/$1"; chmod +x "$R/bin/$1"; }
        stub getent  "f=\"$R/group.\$2\"; [[ \"\$1\" == group && -f \"\$f\" ]] && cat \"\$f\" || exit 2"
        stub id      'case "$1" in -gn) echo "$2";; esac; case "${@: -1}" in appa|appb|nodeapp|staticnode|newapp|admin|sysuser|root|cipi|www-data) exit 0;; *) exit 1;; esac'
        stub gpasswd "echo \"gpasswd \$*\" >> \"$R/calls\"; [[ \"\$1\" == -d ]] && sed -i -E \"s/(:|,)\$2(,|\\\$)/\\\\1\\\\2/; s/,\\\$//; s/:,/:/\" \"$R/group.\$3\""
        stub dpkg    '[[ "$2" == php8.3-fpm || "$2" == php8.4-fpm ]]'
        stub systemctl "echo \"systemctl \$*\" >> \"$R/calls\"; exit 0"
        stub php-fpm8.3 "echo \"php-fpm8.3 \$*\" >> \"$R/calls\"; exit \${FPM83_T_RC:-0}"
        stub php-fpm8.4 "echo \"php-fpm8.4 \$*\" >> \"$R/calls\"; exit 0"
        # nginx -t fails when told to: always (NGINX_T_RC), or as soon as appa's vhost names the new directory (NGINX_REJECT_NEW)
        stub nginx   "echo \"nginx \$*\" >> \"$R/calls\"; [[ -n \"\${NGINX_T_RC:-}\" ]] && exit \"\$NGINX_T_RC\"; if [[ -n \"\${NGINX_REJECT_NEW:-}\" ]] && grep -qs 'cipi-apps/appa/' \"$R/etc/nginx/sites-available/appa\"; then exit 1; fi; exit 0"
        stub supervisorctl "echo \"supervisorctl \$*\" >> \"$R/calls\"
case \"\$1 \$2\" in
  'reread '*) exit \${SUP_REREAD_RC:-0};;
  'update appa-worker-default') printf 'appa-worker-default: stopped\nappa-worker-default: updated process group\n';;
  'status appa-worker-default:*') printf 'appa-worker-default:appa-worker-default_00   RUNNING   pid 11, uptime 1:00:00\nappa-worker-default:appa-worker-default_01   RUNNING   pid 12, uptime 1:00:00\n';;
  'status appa-reverb:*')         printf 'appa-reverb                      RUNNING   pid 13, uptime 1:00:00\n';;
  'status appa-horizon:*')        printf 'appa-horizon                     STOPPED   Not started\n'; exit 3;;
  status*) echo \"\$2: ERROR (no such group)\"; exit 4;;
esac"
        # the real switch rewrites the two slots' configuration itself: so does this one
        stub cipi-node-switch "echo \"node-switch \$* SUDO_USER=\${SUDO_USER:-unset}\" >> \"$R/calls\"; [[ \"\${NODE_SWITCH_RC:-0}\" == 0 ]] || exit \"\$NODE_SWITCH_RC\"; sed -i \"s#^stdout_logfile=$R/home/\$1/logs/#stdout_logfile=$R/var/log/cipi-apps/\$1/#\" \"$R/etc/supervisor/conf.d/\$1-node.conf\""
        # the drop to the app user, ownership and ACLs: here everything is the user running the test
        stub sudo    'if [[ "$1" == -u ]]; then shift 2; fi; exec "$@"'
        stub install 'args=(); while [[ $# -gt 0 ]]; do case "$1" in -o|-g) shift 2;; *) args+=("$1"); shift;; esac; done; exec /usr/bin/install "${args[@]}"'
        stub chown   'exit 0'
        stub setfacl 'exit 0'
        stub crontab "if [[ \"\$1\" == -l ]]; then cat \"$R/crontab\" 2>/dev/null; elif [[ \"\$1\" == - ]]; then cat > \"$R/crontab\"; echo 'crontab -' >> \"$R/calls\"; fi"

        # Five apps — appa (Laravel: workers, horizon, a pool on 8.3), appb (not
        # in www-data, a pool someone rewrote), nodeapp (Node SSR), staticnode
        # (Node static), newapp (created on 5.8.6) — an app with a reserved
        # name, and an account that is in www-data and is not an app.
        echo '{"appa":{},"appb":{},"nodeapp":{},"staticnode":{},"newapp":{},"admin":{}}' > "$R/cfg/apps.json"
        printf 'cipi-apps:x:1001:appa,appb,nodeapp,staticnode,newapp\n' > "$R/group.cipi-apps"
        printf 'www-data:x:33:appa,nodeapp,staticnode,admin,sysuser\n' > "$R/group.www-data"
        printf '[www]\nuser = www-data\ngroup = www-data\nlisten = /run/php/php8.3-fpm.sock\nlisten.owner = www-data\nlisten.group = www-data\npm = ondemand\n' \
            > "$R/etc/php/8.3/fpm/pool.d/www.conf"
        local a
        for a in appa appb nodeapp newapp; do
            mkdir -p "$R/home/$a/logs"
            printf 'server {\n    listen 443 ssl;\n    server_name %s.example.com;\n    access_log %s/home/%s/logs/nginx-access.log;\n    error_log %s/home/%s/logs/nginx-error.log;\n}\n\nserver {\n    listen 80;\n    server_name %s.example.com;\n    access_log %s/home/%s/logs/nginx-access.log;\n    error_log %s/home/%s/logs/nginx-error.log;\n    return 301 https://$host$request_uri;\n}\n' \
                "$a" "$R" "$a" "$R" "$a" "$a" "$R" "$a" "$R" "$a" > "$R/etc/nginx/sites-available/$a"
        done
        sed -i "s#$R/home/newapp/logs/#$R/var/log/cipi-apps/newapp/#" "$R/etc/nginx/sites-available/newapp"
        printf '[program:appa-worker-default]\ncommand=/usr/bin/php8.3 artisan queue:work\nuser=appa\nnumprocs=2\nstdout_logfile=%s/home/appa/logs/worker-default.log\nstdout_logfile_maxbytes=10MB\n[program:appa-horizon]\ncommand=/usr/bin/php8.3 artisan horizon\nuser=appa\nstdout_logfile=%s/home/appa/logs/horizon.log\n[program:appa-reverb]\ncommand=/usr/bin/php8.3 artisan reverb:start\nuser=appa\nstdout_logfile=/var/log/custom/appa-reverb.log\n' \
            "$R" "$R" > "$R/etc/supervisor/conf.d/appa.conf"
        printf '[program:nodeapp-node-blue]\nstdout_logfile=%s/home/nodeapp/logs/node-blue.log\n[program:nodeapp-node-green]\nstdout_logfile=%s/home/nodeapp/logs/node-green.log\n' "$R" "$R" \
            > "$R/etc/supervisor/conf.d/nodeapp-node.conf"
        : > "$R/etc/supervisor/conf.d/staticnode-node.conf"
        echo '{"mode":"ssr","active":0}' > "$R/var/lib/cipi/node/nodeapp.json"
        echo '{"mode":"static"}' > "$R/var/lib/cipi/node/staticnode.json"
        ln -s releases/7 "$R/home/nodeapp/current"; ln -s . "$R/home/staticnode/current"
        printf '[appa]\nuser = appa\nlisten = /run/php/appa.sock\nphp_admin_value[open_basedir] = %s/home/appa/:/tmp/:/proc/\nphp_admin_value[error_log] = %s/home/appa/logs/php-fpm-error.log\n' "$R" "$R" \
            > "$R/etc/php/8.3/fpm/pool.d/appa.conf"
        printf '[appb]\nuser = appb\nphp_admin_value[open_basedir] = %s/home/appb/htdocs/:/srv/shared/\n' "$R" > "$R/etc/php/8.4/fpm/pool.d/appb.conf"
        echo 'old access line' > "$R/home/appa/logs/nginx-access.log"; echo 'old error line' > "$R/home/appa/logs/nginx-error.log"
        echo '[2026-11-01 10:00:00] ===== deploy OK  app=appa =====' > "$R/home/appa/logs/deploy.log"
        echo 'old worker line' > "$R/home/appa/logs/worker-default.log"; echo 'fpm line' > "$R/home/appa/logs/php-fpm-error.log"
        printf '%s/home/*/shared/storage/logs/*[!0-9].log\n%s/home/*/logs/php-fpm-*.log\n%s/home/*/logs/worker-*.log\n%s/home/*/logs/deploy.log\n/var/log/cipi/*.log {\n    daily\n    copytruncate\n}\n' "$R" "$R" "$R" "$R" > "$R/etc/logrotate.d/cipi-app-logs"
        printf '%s/home/*/logs/nginx-access.log\n%s/home/*/logs/nginx-error.log\n/var/log/nginx/*.log {\n    daily\n    copytruncate\n}\n' "$R" "$R" > "$R/etc/logrotate.d/cipi-http-logs"
        printf 'filenames:\n  - /var/log/nginx/access.log\n  - %s/home/*/logs/nginx-access.log\n  - %s/home/*/logs/nginx-error.log\nlabels:\n  type: nginx\n' "$R" "$R" > "$R/etc/crowdsec/acquis.d/cipi-nginx.yaml"
        printf '# === CIPI CRON JOBS ===\n50 3 * * * /usr/local/bin/cipi-cron-notify self-update /usr/local/bin/cipi self-update >> /var/log/cipi/cipi.log 2>&1\n50 5 * * * echo 3 > /proc/sys/vm/drop_caches && swapoff -a && swapon -a 2>/dev/null\n0 1 * * * /root/my-own-job.sh\n' > "$R/crontab"
        echo 'www-data ALL=(root) NOPASSWD: /usr/local/bin/cipi ssh add *' > "$R/etc/sudoers.d/cipi-api"
        : > "$R/calls"
    }
    migrate() {   # [VAR=value…]
        : > "$R/calls"
        ( cd "$R" && env "$@" PATH="$R/bin:$PATH" CIPI_LIB="$R/lib" CIPI_CONFIG="$R/cfg" CIPI_LOG="$R/log" \
            CIPI_API_ROOT="$R/opt/api" CIPI_GUI_ROOT="$R/opt/gui" SUDO_USER=cipi bash "$R/migration.sh" ) > "$R/out" 2>&1
    }
    relocate() {   # [VAR=value…] -- [app_logs_relocate arguments]  — what `cipi app fix-permissions` calls
        local -a ev=()
        while [[ $# -gt 0 && "$1" != -- ]]; do ev+=("$1"); shift; done
        [[ "${1:-}" == -- ]] && shift
        : > "$R/calls"
        ( cd "$R" && env "${ev[@]}" PATH="$R/bin:$PATH" CIPI_LIB="$R/lib" CIPI_CONFIG="$R/cfg" CIPI_LOG="$R/log" SUDO_USER=cipi \
            bash -c 'set -euo pipefail; source "$CIPI_LIB/common.sh"; source "$CIPI_LIB/app-logs.sh"; app_logs_relocate "$@"; echo "LEFT=${APP_LOGS_LEFT}"' _ "$@" ) > "$R/out" 2>&1
    }
    snap()   { ( cd "$R" && find etc/nginx etc/supervisor etc/php etc/logrotate.d etc/crowdsec -type f -exec cksum {} + | sort -k3; cksum crontab ); }
    called() { grep -qx -- "$1" "$R/calls"; }
    ncalls() { grep -c -- "$1" "$R/calls"; }
    old_in() { grep -c "$R/home/$1/logs/$2" "$3" 2>/dev/null; }
    new_in() { grep -c "$R/var/log/cipi-apps/$1/$2" "$3" 2>/dev/null; }
    islink() { [[ -L "$R/home/$1/logs/$2" && "$(readlink "$R/home/$1/logs/$2")" == "$R/var/log/cipi-apps/$1/$2" ]]; }

    build_root
    cp "$R/etc/nginx/sites-available/newapp" "$R/newapp.before"; cp "$R/etc/php/8.4/fpm/pool.d/appb.conf" "$R/appb-pool.before"
    migrate; rc=$?
    [[ "$rc" -eq 0 ]] && grep -q 'Migration 5.8.6 complete' "$R/out" && pass "migration runs to the end (exit 0)" || { fail "migration aborted (rc=${rc})"; sed 's/^/    /' "$R/out" >&2; }
    [[ "$(ncalls '^gpasswd -d')" -eq 3 ]] && called 'gpasswd -d appa www-data' && called 'gpasswd -d nodeapp www-data' && called 'gpasswd -d staticnode www-data' \
        && pass "the three app users in www-data are removed, and only they" || fail "wrong gpasswd calls: $(tr '\n' ';' < "$R/calls")"
    [[ "$(cut -d: -f4 "$R/group.www-data")" == "admin,sysuser" ]] \
        && pass "an account that is not an app stays in www-data" || fail "www-data members after: $(cat "$R/group.www-data")"
    grep -q 'WARNING: admin: listed as an app but not an app-shaped name' "$R/out" \
        && pass "an app with a reserved name is reported, not skipped in silence" || fail "reserved-name app skipped without a word"
    grep -q '^listen.mode = 0600$' "$R/etc/php/8.3/fpm/pool.d/www.conf" && pass "www pool gets listen.mode = 0600" || fail "www.conf not updated"
    [[ ! -e "$R/etc/sudoers.d/cipi-api" ]] && pass "panel sudoers removed on a server with no panel" || fail "panel sudoers left behind"
    [[ "$(ncalls '^systemctl restart php8.3-fpm$')" -eq 1 ]] && pass "PHP-FPM restarted, once" || fail "PHP-FPM 8.3 restarts: $(ncalls '^systemctl restart php8.3-fpm$')"

    # nginx
    [[ "$(old_in appa nginx- "$R/etc/nginx/sites-available/appa")" -eq 0 && "$(new_in appa nginx- "$R/etc/nginx/sites-available/appa")" -eq 4 \
       && "$(old_in appb nginx- "$R/etc/nginx/sites-available/appb")" -eq 0 && "$(old_in nodeapp nginx- "$R/etc/nginx/sites-available/nodeapp")" -eq 0 ]] \
        && pass "vhosts: every access_log and error_log now names /var/log/cipi-apps/<app>" || fail "vhosts not rewritten"
    cmp -s "$R/etc/nginx/sites-available/newapp" "$R/newapp.before" && pass "a vhost already on the new directory is not touched" || fail "newapp vhost changed"
    [[ "$(ncalls '^nginx -t$')" -eq 2 && "$(ncalls '^systemctl reload nginx$')" -eq 1 ]] \
        && [[ "$(grep -n -m1 '^systemctl reload nginx$' "$R/calls" | cut -d: -f1)" -gt "$(grep -n '^nginx -t$' "$R/calls" | tail -1 | cut -d: -f1)" ]] \
        && pass "nginx -t before the edit and after it, then one reload" || fail "nginx calls: $(grep -E '^nginx|nginx$' "$R/calls" | tr '\n' ';')"
    islink appa nginx-access.log && islink appa nginx-error.log && [[ "$(cat "$R/home/appa/logs/nginx-access.log.old")" == "old access line" ]] \
        && pass "~/logs/nginx-*.log are symlinks to the new files; the old logs are kept as .old" || fail "appa ~/logs: $(ls -l "$R/home/appa/logs" | awk '{print $9,$10,$11}' | tr '\n' ';')"

    # supervisor
    [[ "$(old_in appa '' "$R/etc/supervisor/conf.d/appa.conf")" -eq 0 && "$(new_in appa worker-default.log "$R/etc/supervisor/conf.d/appa.conf")" -eq 1 \
       && "$(new_in appa horizon.log "$R/etc/supervisor/conf.d/appa.conf")" -eq 1 ]] && grep -qx 'stdout_logfile=/var/log/custom/appa-reverb.log' "$R/etc/supervisor/conf.d/appa.conf" \
        && pass "supervisor: the programs that logged to ~/logs log to /var/log/cipi-apps/<app>; a log elsewhere is left where it is" || fail "supervisor conf: $(grep stdout_logfile= "$R/etc/supervisor/conf.d/appa.conf" | tr '\n' ';')"
    called 'supervisorctl reread' && called 'supervisorctl update appa-worker-default' && [[ "$(ncalls '^supervisorctl restart appa-worker-default')" -eq 0 ]] \
        && pass "a running worker is restarted once, on its new configuration (supervisorctl update <group>)" || fail "worker restart: $(grep '^supervisorctl' "$R/calls" | tr '\n' ';')"
    called 'supervisorctl restart appa-reverb' \
        && pass "a running program the move did not restart is restarted for its new groups" || fail "appa-reverb keeps the old groups"
    [[ "$(ncalls '^supervisorctl \(restart\|update\|start\) appa-horizon')" -eq 0 ]] \
        && pass "a stopped program stays stopped" || fail "a stopped program was started by the migration"
    islink appa worker-default.log && islink appa horizon.log && [[ "$(cat "$R/home/appa/logs/worker-default.log.old")" == "old worker line" ]] \
        && pass "~/logs/worker-*.log and horizon.log are symlinks; the old worker log is kept as .old" || fail "worker log links"

    # Node
    [[ "$(ncalls '^node-switch')" -eq 1 ]] && called 'node-switch nodeapp current SUDO_USER=unset' \
        && pass "the Node SSR app is switched blue/green once, without the caller's SUDO_USER; the static one is left alone" \
        || fail "node switch calls: $(grep '^node-switch' "$R/calls" | tr '\n' ';')"
    [[ "$(old_in nodeapp node- "$R/etc/supervisor/conf.d/nodeapp-node.conf")" -eq 0 ]] && pass "the Node slots log to /var/log/cipi-apps/<app>" || fail "node conf not moved"

    # PHP pools, deploy log, logrotate, CrowdSec, cron
    grep -qxF "php_admin_value[open_basedir] = $R/home/appa/:$R/var/log/cipi-apps/appa/:/tmp/:/proc/" "$R/etc/php/8.3/fpm/pool.d/appa.conf" \
        && pass "the app's pool may read /var/log/cipi-apps/<app> (cipi/agent reads ~/logs from PHP)" || fail "appa open_basedir: $(grep open_basedir "$R/etc/php/8.3/fpm/pool.d/appa.conf")"
    cmp -s "$R/etc/php/8.4/fpm/pool.d/appb.conf" "$R/appb-pool.before" && pass "a pool whose open_basedir someone rewrote is left alone" || fail "appb pool changed"
    [[ "$(grep -n -m1 '^php-fpm8.3 -t$' "$R/calls" | cut -d: -f1)" -lt "$(grep -n -m1 '^systemctl restart php8.3-fpm$' "$R/calls" | cut -d: -f1)" ]] \
        && pass "the FPM configuration is tested before the restart" || fail "FPM restarted untested"
    islink appa deploy.log && [[ "$(head -1 "$R/var/log/cipi-apps/appa/deploy.log")" == '[2026-11-01 10:00:00] ===== deploy OK  app=appa =====' ]] \
        && pass "deploy.log moves too, and starts from the old one's lines" || fail "deploy.log not carried over"
    [[ "$(cat "$R/home/appa/logs/php-fpm-error.log")" == "fpm line" && ! -L "$R/home/appa/logs/php-fpm-error.log" ]] \
        && pass "the app's own logs (php-fpm-error.log) stay in ~/logs" || fail "php-fpm-error.log was touched"
    ! grep -qE '/home/\*/logs/(nginx-|worker-|deploy)' "$R/etc/logrotate.d/cipi-app-logs" "$R/etc/logrotate.d/cipi-http-logs" \
        && grep -qxF "$R/var/log/cipi-apps/*/nginx-access.log" "$R/etc/logrotate.d/cipi-http-logs" && grep -qxF "$R/var/log/cipi-apps/*/worker-*.log" "$R/etc/logrotate.d/cipi-app-logs" \
        && grep -qxF "$R/home/*/logs/php-fpm-*.log" "$R/etc/logrotate.d/cipi-app-logs" \
        && pass "logrotate rotates the logs where they are now" || fail "logrotate: $(cat "$R/etc/logrotate.d/cipi-http-logs" | head -3 | tr '\n' ';')"
    grep -qF -- "- $R/var/log/cipi-apps/*/nginx-access.log" "$R/etc/crowdsec/acquis.d/cipi-nginx.yaml" && ! grep -q '/home/\*/logs' "$R/etc/crowdsec/acquis.d/cipi-nginx.yaml" \
        && called 'systemctl reload crowdsec' && pass "CrowdSec reads the nginx logs where they are now" || fail "crowdsec acquis not updated"
    [[ "$(wc -l < "$R/crontab")" -eq 4 ]] && grep -q '^50 5 \* \* \* echo 3 > /proc/sys/vm/drop_caches && awk .*/proc/meminfo && swapoff -a && swapon -a' "$R/crontab" \
        && grep -qx '0 1 \* \* \* /root/my-own-job.sh' "$R/crontab" && grep -q 'cipi self-update' "$R/crontab" \
        && pass "root's crontab: the swap line gets its memory check, every other line is as it was" || fail "crontab: $(cat "$R/crontab" | cut -c1-80 | tr '\n' ';')"
    [[ -n "$(find "$R/var/lib/cipi/app-logs-backup" -type f -name 'appa.conf' 2>/dev/null)" && "$(find "$R/var/lib/cipi/app-logs-backup" -type f | wc -l)" -eq 5 ]] \
        && pass "every file edited has a copy in /var/lib/cipi/app-logs-backup" || fail "backups: $(find "$R/var/lib/cipi/app-logs-backup" -type f | wc -l) file(s)"

    snap > "$R/snap.1"
    migrate; rc=$?
    snap > "$R/snap.2"
    [[ "$rc" -eq 0 && ! -s "$R/calls" ]] && grep -q 'No app user in www-data' "$R/out" && cmp -s "$R/snap.1" "$R/snap.2" \
        && pass "second run changes nothing (idempotent)" || fail "second run: rc=${rc}, calls=$(tr '\n' ';' < "$R/calls")"

    # A Node process that does not come up, and a panel that is installed.
    printf 'www-data:x:33:nodeapp\n' > "$R/group.www-data"
    echo '{"domain":"panel.example.com"}' > "$R/cfg/api.json"
    echo 'kept' > "$R/etc/sudoers.d/cipi-api"
    migrate NODE_SWITCH_RC=1; rc=$?
    [[ "$rc" -eq 0 ]] && grep -q 'WARNING: nodeapp: Node process not restarted' "$R/out" \
        && pass "a Node switch that fails is a warning, not an aborted migration" || fail "failed node switch: rc=${rc}"
    [[ "$(cat "$R/etc/sudoers.d/cipi-api" 2>/dev/null)" == "kept" ]] \
        && pass "panel sudoers untouched where a panel is installed" || fail "panel sudoers changed on a server with a panel"

    # ── the move, when a service says no: everything goes back ──
    build_root; cp -r "$R/etc/nginx" "$R/nginx.before"; cp "$R/etc/crowdsec/acquis.d/cipi-nginx.yaml" "$R/acquis.before"
    migrate NGINX_REJECT_NEW=1; rc=$?
    [[ "$rc" -eq 0 ]] && grep -q 'WARNING: nginx refused the vhosts with the new log directory' "$R/out" && diff -r "$R/etc/nginx" "$R/nginx.before" >/dev/null \
        && [[ "$(ncalls '^systemctl reload nginx$')" -eq 0 ]] \
        && pass "nginx refuses the new vhosts → every vhost byte for byte as before, no reload, migration goes on" || fail "nginx refusal: rc=${rc}"
    [[ ! -L "$R/home/appa/logs/nginx-access.log" && "$(cat "$R/home/appa/logs/nginx-access.log")" == "old access line" ]] && cmp -s "$R/etc/crowdsec/acquis.d/cipi-nginx.yaml" "$R/acquis.before" \
        && grep -qxF "$R/home/*/logs/nginx-access.log" "$R/etc/logrotate.d/cipi-http-logs" \
        && pass "…and the nginx logs, their rotation and CrowdSec stay on ~/logs" || fail "nginx refusal left ~/logs half moved"
    grep -q 'still log to ~/logs' "$R/out" && pass "…and the migration says what is left and how to retry" || fail "nothing said about what is left"
    relocate --; rc=$?
    [[ "$rc" -eq 0 && "$(old_in appa nginx- "$R/etc/nginx/sites-available/appa")" -eq 0 ]] && grep -qx 'LEFT=0' "$R/out" && islink appa nginx-access.log \
        && ! grep -q '/home/\*/logs/nginx-' "$R/etc/logrotate.d/cipi-http-logs" \
        && pass "cipi app fix-permissions finishes the move once nginx accepts it" || fail "retry: rc=${rc} $(tail -1 "$R/out")"

    build_root; cp -r "$R/etc/nginx" "$R/nginx.before"
    relocate NGINX_T_RC=1 --; rc=$?
    [[ "$rc" -eq 0 && "$(ncalls '^nginx -t$')" -eq 1 && "$(ncalls 'reload nginx')" -eq 0 ]] && diff -r "$R/etc/nginx" "$R/nginx.before" >/dev/null \
        && grep -q "does not pass 'nginx -t' as it is" "$R/out" \
        && pass "an nginx configuration that was already broken is not touched" || fail "broken nginx: rc=${rc}"

    build_root; cp "$R/etc/supervisor/conf.d/appa.conf" "$R/appa-sup.before"
    relocate SUP_REREAD_RC=1 --; rc=$?
    [[ "$rc" -eq 0 ]] && cmp -s "$R/etc/supervisor/conf.d/appa.conf" "$R/appa-sup.before" && [[ ! -L "$R/home/appa/logs/worker-default.log" ]] \
        && [[ "$(ncalls '^supervisorctl update')" -eq 0 ]] && grep -qxF "$R/home/*/logs/worker-*.log" "$R/etc/logrotate.d/cipi-app-logs" \
        && pass "supervisorctl reread fails → the program files go back, no worker is restarted, its log stays a file in ~/logs" || fail "supervisor failure: rc=${rc}"

    build_root; cp "$R/etc/php/8.3/fpm/pool.d/appa.conf" "$R/appa-pool.before"
    relocate FPM83_T_RC=1 --; rc=$?
    [[ "$rc" -eq 0 ]] && cmp -s "$R/etc/php/8.3/fpm/pool.d/appa.conf" "$R/appa-pool.before" && [[ "$(ncalls 'php8.3-fpm$')" -eq 0 ]] \
        && pass "php-fpm -t fails with the new open_basedir → the pool goes back, FPM is not reloaded" || fail "fpm failure: rc=${rc}"

    build_root
    relocate -- appa; rc=$?
    [[ "$rc" -eq 0 && "$(old_in appa nginx- "$R/etc/nginx/sites-available/appa")" -eq 0 && "$(old_in appb nginx- "$R/etc/nginx/sites-available/appb")" -eq 4 \
       && "$(ncalls '^node-switch')" -eq 0 ]] && called 'systemctl reload php8.3-fpm' \
        && grep -qxF "$R/home/*/logs/nginx-access.log" "$R/etc/logrotate.d/cipi-http-logs" && grep -qxF "$R/var/log/cipi-apps/*/nginx-access.log" "$R/etc/logrotate.d/cipi-http-logs" \
        && pass "cipi app fix-permissions <app> moves that app only; logrotate covers both places while other apps are on ~/logs" || fail "single app: rc=${rc}"
fi

# ── 12. root and an app's home ──────────────────────────────
# Root does not open, write, chown or chmod a path inside the home of an app
# that exists: the app user does (app_as and the helpers on it, common.sh).
echo "--- static: root and an app's home"
# X | hasq [grep options] PATTERN — grep -q on a pipe, with all of the input
# read first: grep -q stops at the first match, the writer of a long input is
# left with a closed pipe, and pipefail reports the match as a failure.
hasq() { local t; t=$(cat); grep -q "$@" <<< "$t"; }
for f in app_as app_sh app_call app_of_path _app_reown _app_dir_do _app_own_check _app_file_op app_read app_write app_append app_sed app_rm app_mkdir; do
    [[ -n "$(fn common.sh "$f")" ]] || fail "common.sh has no ${f}"
done
fn common.sh app_as | hasq 'sudo -u "\$app" -- "\$@"' && fn common.sh app_as | hasq 'EUID' \
    && pass "app_as: root drops to the app user, anyone else runs the command as it is" || fail "app_as"
fn common.sh app_of_path | hasq 'EUID' && fn common.sh app_of_path | hasq -F '^/home/([a-z][a-z0-9]{2,31})/' \
    && pass "app_of_path: an app's home, for root only" || fail "app_of_path"
for f in _env_read_key _env_to_json _env_set_key _env_unset_key _env_set_or_add _env_apply_group _env_remove_keys; do
    fn app.sh "$f" | sed -n 2p | hasq "app_of_path .*app_call \"\\\$_o\" \"${f}[ \"]" \
        || fail "app.sh ${f} does not hand itself to the app user first"
done
for f in _search_env_get _search_env_set _search_env_del _search_env_block; do
    fn search.sh "$f" | sed -n 2p | hasq "app_of_path .*app_call \"\\\$_o\" \"${f}[ \"]" \
        || fail "search.sh ${f} does not hand itself to the app user first"
done
[[ "$FAIL" -eq 0 ]] && pass "the .env functions (app.sh, search.sh) run as the app user on an app's .env"
for f in _env_set_or_add _env_apply_group; do
    fn app.sh "$f" | hasq -F "sed 's/[\\\\&|]/\\\\&/g'" || fail "app.sh ${f} puts the value into the sed script as it is"
done
fn search.sh _search_env_set | hasq -F "sed 's/[\\\\&|]/\\\\&/g'" \
    && pass ".env values are escaped before sed sees them (a \"|\" ended the replacement: |e ran what followed)" || fail "search.sh _search_env_set does not escape the value"
code() { grep -vE '^[[:space:]]*#' "${LIB}/$1"; }
fnc() { fn "$@" | grep -vE '^[[:space:]]*#'; }   # a function without its comments (they tell what root used to do)
code app.sh | hasq -E 'chown "\$\{(app|name)\}:\$\{(app|name)\}" "\$(env_file|envf|dst_env|auth_file)"' \
    && fail "app.sh still chowns .env / auth.json by path" || pass "app.sh: no chown of .env or auth.json by path"
code search.sh | hasq -E 'chown "\$\{app\}:\$\{app\}" "\$envf"' \
    && fail "search.sh still chowns .env by path" || pass "search.sh: no chown of .env by path"
tpl=$(fnc app.sh _create_deployer_config_from_template)
grep -qE 'chown -R|> "\$\{dh\}/\.deployer/deploy\.php"' <<< "$tpl" \
    && fail "deploy.php is still written and chowned by root" || pass "deploy.php is written by the app user (no root write, no chown -R of ~/.deployer)"
grep -q 'if \[\[ -n "\$extra_task" \]\]; then' <<< "$tpl" && ! grep -q '\[\[ -n "\$extra_task" \]\] &&' <<< "$tpl" \
    && pass "the recipe loop ends on an if (its status counts, now that it feeds a pipeline)" || fail "recipe loop can end on a false test under pipefail"
fnc common.sh deployer_audit_ensure_hook | hasq -E '>> "\$df"|chown' \
    && fail "the audit hook is still appended by root" || pass "the audit hook is appended by the app user"
fnc common.sh _sync_node_build_script | hasq -E 'cat > |chown|chmod 750 "' \
    && fail "node-build.sh is still written by root" || pass "node-build.sh is written by the app user"
fnc node.sh _node_webhook_config | hasq -E 'chown|> "\$\{dir\}/webhook\.json"' \
    && fail "~/.cipi/webhook.json is still written by root" || pass "~/.cipi/webhook.json is written by the app user"
fnc node.sh _node_recipe_config_write | hasq -E '> "\$\{f\}\.tmp"|chown' \
    && fail "~/.deployer/node.json is still written by root" || pass "~/.deployer/node.json is written by the app user"
rot=$(fnc git.sh _git_rotate_local_key)
grep -qE 'chown|mkdir -p "\$\{home\}|^[[:space:]]*touch "\$ak"$' <<< "$rot" || ! grep -q 'app_mkdir "\$app" "\${home}/.ssh" 700' <<< "$rot" \
    && fail "_git_rotate_local_key still works in ~/.ssh as root" || pass "the deploy key is rotated in ~/.ssh by the app user"
logs=$(fnc common.sh ensure_app_logs_permissions)
grep -q '_app_dir_do "\$app" shared/storage/logs chown -h -R --from=root' <<< "$logs" && ! grep -qE 'chown .*"\$\{home\}/(logs|shared/storage/logs)"' <<< "$logs" \
    && pass "root-owned logs are reclaimed from inside the directory, and only if no link is on the way to it" || fail "ensure_app_logs_permissions still chowns a path under the home"
[[ "$(grep -c -- '-pass env:CIPI_SYNC_PASSPHRASE' "${LIB}/sync.sh")" -eq 3 ]] && ! code sync.sh | hasq -- '-pass pass:' \
    && pass "sync: the passphrase reaches openssl through the environment, not the command line" || fail "sync: passphrase on the openssl command line"
fnc sync.sh _sync_update_app | hasq -E '(^|[^_])(cp|tar -xzf) .*"\$\{home\}/|chown -R ' \
    && fail "sync update still copies into the home as root" || pass "sync update writes .env, auth.json, storage and deploy.php as the app user"
code deploy.sh | hasq '/tmp/cipi-predeploy-' \
    && fail "deploy.sh still keeps the snapshot path in /tmp" || pass "the pre-deploy snapshot path is not kept in a file under /tmp"
fn deploy.sh _deploy_commit_info | hasq 'app_as "\$app" git ' && fn deploy.sh _deploy_releases | hasq 'app_as "\$app" git ' \
    && pass "git reads a release as the app user (root does not run it on a tree the app controls)" || fail "git still runs as root on the app's releases"
code cipi-deploy-audit.sh | hasq "safe.directory" || ! code cipi-deploy-audit.sh | hasq '_as_app git -C' \
    && fail "cipi-deploy-audit still runs git as root with safe.directory=*" || pass "cipi-deploy-audit reads REVISION, the repository and releases_log as the app user"
grep -q 'runuser -u "\$app" -- setsid -w timeout' "${LIB}/php.sh" \
    && pass "the FrankenPHP binary of an app is asked its version without a terminal" || fail "php.sh runs the app's binary on root's terminal"
grep -q 'pwd -P' "${LIB}/cipi-scan-manifest.sh" && fn scan.sh _scan_hash_tree | hasq 'is not inside' \
    && pass "integrity hashing stays inside the app's home" || fail "integrity hashing follows current/htdocs anywhere"
fnc scan.sh _scan_hash_tree | hasq 'err=\$(_scan_hash_err)' \
    && fail "_scan_hash_tree names its error file in a subshell (errors were never seen)" || pass "_scan_hash_tree keeps the name of its error file"

echo "--- functional: the helpers, on a fake home"
AH="${TMP}/ah"; S12="${TMP}/s12"; mkdir -p "$AH/demo/shared" "$S12"
# The app is a directory, not a user: sudo runs the command as whoever runs the test.
printf '%s\n' '#!/bin/bash' 'while [[ "${1:-}" == -* ]]; do case "$1" in -u) shift 2 ;; --) shift; break ;; *) shift ;; esac; done' 'exec "$@"' > "$S12/sudo"
chmod +x "$S12/sudo"
hlp=$(for f in app_as app_sh app_call app_of_path _app_reown _app_dir_do _app_own_check _app_file_op app_read app_write app_append app_sed app_rm app_mkdir; do fn common.sh "$f"; done | sed "s#/home/#${AH}/#g")
run12() { PATH="$S12:$PATH" bash -c "${hlp}"$'\n'"set -euo pipefail"$'\n'"$1"; }
mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
E="$AH/demo/shared/.env"
printf 'A=1\n' | run12 "app_write demo '$E' 640"
[[ "$(cat "$E")" == "A=1" && "$(mode "$E")" == "640" ]] && pass "app_write: a new file, with the mode asked for" || fail "app_write new: $(cat "$E" 2>&1) $(mode "$E")"
ino=$(ls -i "$E" | awk '{print $1}')
printf 'A=2\nB=x\n' | run12 "app_write demo '$E'"
[[ "$(cat "$E")" == $'A=2\nB=x' && "$(mode "$E")" == "640" && "$(ls -i "$E" | awk '{print $1}')" == "$ino" ]] \
    && pass "app_write: a file that exists is rewritten in place and keeps its mode" || fail "app_write existing: $(mode "$E")"
run12 "app_read demo '$E' | app_write demo '$E'"
[[ "$(cat "$E")" == $'A=2\nB=x' ]] && pass "app_write: all of stdin is taken before the file is opened (a pipeline may read what it writes)" || fail "app_write lost the file it was reading"
printf 'C=3\n' | run12 "app_append demo '$E'"
[[ "$(tail -n 1 "$E")" == "C=3" && "$(wc -l < "$E" | tr -d ' ')" == "3" ]] && pass "app_append" || fail "app_append: $(cat "$E")"
[[ "$(run12 "app_read demo '$E'")" == "$(cat "$E")" ]] && pass "app_read" || fail "app_read"
out=$(run12 "app_read demo '$AH/demo/shared/nope' || echo \"rc=\$?\"")
[[ "$out" == rc=* ]] && pass "app_read: a file that is not there is nothing, and a status" || fail "app_read missing: '${out}'"
run12 "app_mkdir demo '$AH/demo/.cipi/x' 700 && app_rm demo '$E.gone' '$AH/demo/shared/nope'"
[[ -d "$AH/demo/.cipi/x" && "$(mode "$AH/demo/.cipi/x")" == "700" ]] && pass "app_mkdir (with a mode), app_rm of files that are not there" || fail "app_mkdir: $(mode "$AH/demo/.cipi/x")"
out=$(run12 "inner() { echo \"got:\$1\"; }; outer() { inner \"\$@\"; return 7; }; app_call demo 'outer inner' outer 'a b' || echo \"rc=\$?\"")
[[ "$out" == $'got:a b\nrc=7' ]] && pass "app_call: a function, the one it calls, its arguments and its status" || fail "app_call: '${out}'"
if sed --version >/dev/null 2>&1; then
    run12 "app_sed demo '$E' 's|^A=.*|A=9|'"
    [[ "$(head -n 1 "$E")" == "A=9" && "$(mode "$E")" == "640" ]] && pass "app_sed" || fail "app_sed: $(cat "$E")"

    echo "--- functional: a .env value is data"
    V=";touch ${TMP}/ran;|e;s|a|b"
    for spec in "app.sh _env_set_or_add" "search.sh _search_env_set"; do
        f="${spec#* }"; printf 'K=old\nZ=1\n' > "$E"; rm -f "${TMP}/ran"
        VAL="$V" run12 "$(fn "${spec% *}" "$f" | sed "s#/home/#${AH}/#g"); $f '$E' K \"\$VAL\""
        [[ ! -e "${TMP}/ran" && "$(head -n 1 "$E")" == "K=${V}" && "$(tail -n 1 "$E")" == "Z=1" ]] \
            && pass "${f}: a value with |e in it is written, not run" || fail "${f}: $(head -n 1 "$E") ran=$([[ -e "${TMP}/ran" ]] && echo yes || echo no)"
    done
    printf 'K=old\nZ=1\n' > "$E"; rm -f "${TMP}/ran"
    VAL="$V" run12 "$(fn app.sh _env_read_key; fn app.sh _env_apply_group | sed "s#/home/#${AH}/#g"); _env_apply_group '$E' false '# x' \"K=\$VAL\" 'N=new & old | both'"
    [[ ! -e "${TMP}/ran" && "$(head -n 1 "$E")" == "K=${V}" ]] && grep -qxF 'N=new & old | both' "$E" \
        && pass "_env_apply_group: the same, and \"&\" and \"|\" arrive as written" || fail "_env_apply_group: $(tr '\n' ' ' < "$E")"
else
    echo "  SKIP: not GNU sed — the sed -i checks are not run"
fi

echo "--- functional: sync update keeps the local database settings without sed"
mkdir -p "${TMP}/ad12"
printf 'APP_NAME=FromSource\nDB_CONNECTION=mysql\nDB_HOST=10.0.0.5\nDB_DATABASE=src\nDB_USERNAME=src\nDB_PASSWORD=srcpass\nDB_PASSWORD_OLD=keep\nMAIL_HOST=smtp\n' > "${TMP}/ad12/env"
printf 'APP_NAME=Local\nDB_CONNECTION=pgsql\nDB_HOST=127.0.0.1\nDB_DATABASE=demo\nDB_USERNAME=demo\nDB_PASSWORD=p|a&ss;touch %s/ran2;|e\n' "$TMP" > "$E"; chmod 640 "$E"
blk=$(sed -n '/^    # 1\. \.env/,/^    # 2\. auth\.json/p' "${LIB}/sync.sh" | sed '$d')
run12 "step() { :; }; success() { :; }; laravel_app_env_single_log() { :; }
f12() {
${blk}
}
app=demo; home='$AH/demo'; ad='${TMP}/ad12'; f12"
[[ ! -e "${TMP}/ran2" && "$(grep -c . "$E")" == "8" ]] && grep -qx 'APP_NAME=FromSource' "$E" && grep -qx 'DB_CONNECTION=pgsql' "$E" && grep -qx 'DB_HOST=127.0.0.1' "$E" \
   && grep -qxF "DB_PASSWORD=p|a&ss;touch ${TMP}/ran2;|e" "$E" && grep -qx 'DB_PASSWORD_OLD=keep' "$E" && grep -qx 'MAIL_HOST=smtp' "$E" && [[ "$(mode "$E")" == "640" ]] \
    && pass "the source's .env with this server's DB_* — a password with | & ; in it kept as it is, nothing run" || fail "sync .env: $(tr '\n' ' ' < "$E") ran=$([[ -e "${TMP}/ran2" ]] && echo yes || echo no)"

echo "--- functional: integrity hashing"
if command -v sha256sum >/dev/null 2>&1; then
    mkdir -p "$AH/demo/releases/1/app" "${TMP}/elsewhere" "${TMP}/s12b"
    echo a > "$AH/demo/releases/1/app/A.php"; echo b > "$AH/demo/releases/1/app/B.php"; echo x > "${TMP}/elsewhere/secret"
    ln -sfn releases/1 "$AH/demo/current"
    scn="$(fn scan.sh _scan_hash_err; fn scan.sh _scan_hash_err_clear; fn scan.sh _scan_hash_tree; fn scan.sh _scan_hash_errors)"
    out=$(bash -c "${scn}"$'\n'"_scan_hash_tree '$AH/demo/current' | wc -l; [[ -z \"\$(_scan_hash_errors)\" ]] && echo clean; _scan_hash_err_clear")
    [[ "$(tr -d ' ' <<< "$out")" == $'2\nclean' ]] && pass "_scan_hash_tree: every file of the release, no error" || fail "_scan_hash_tree: ${out}"
    real=$(command -v sha256sum)
    printf '#!/bin/bash\nrc=0\nfor f in "$@"; do case "$f" in *B.php) echo "sha256sum: $f: Permission denied" >&2; rc=1;; *) %s "$f";; esac; done\nexit $rc\n' "$real" > "${TMP}/s12b/sha256sum"; chmod +x "${TMP}/s12b/sha256sum"
    out=$(PATH="${TMP}/s12b:$PATH" bash -c "${scn}"$'\n'"_scan_hash_tree '$AH/demo/current' >/dev/null; _scan_hash_errors; _scan_hash_err_clear")
    grep -q 'B.php' <<< "$out" && pass "a file that could not be hashed is seen by the caller (it never was: the pass counted as complete)" || fail "hash error lost: '${out}'"
    ln -sfn "${TMP}/elsewhere" "$AH/demo/current"
    out=$(bash -c "${scn}"$'\n'"_scan_hash_tree '$AH/demo/current'; _scan_hash_errors; _scan_hash_err_clear")
    grep -q 'is not inside' <<< "$out" && ! grep -q 'secret' <<< "$out" \
        && pass "current → a directory outside the home: not hashed, and reported as an incomplete pass" || fail "outside tree: '${out}'"
    ln -sfn releases/1 "$AH/demo/current"
else
    echo "  SKIP: sha256sum not installed — hashing checks not run"
fi

if command -v jq >/dev/null 2>&1; then
    echo "--- functional: deploy.php from the template, under set -e"
    mkdir -p "${TMP}/c12" "${TMP}/l12"; rm -rf "$AH/demo/.deployer"
    out=$(PATH="$S12:$PATH" bash -c "export CIPI_LIB='${LIB}' CIPI_CONFIG='${TMP}/c12' CIPI_LOG='${TMP}/l12'; RED=; GREEN=; YELLOW=; CYAN=; DIM=; NC=; BOLD=
        source '${LIB}/common.sh' 2>/dev/null; vault_read() { echo '{\"demo\":{\"php\":\"8.4\",\"branch\":\"main\"}}'; }; source '${LIB}/app.sh' 2>/dev/null
        for f in _create_deployer_config_from_template deployer_audit_ensure_hook; do eval \"\$(declare -f \$f | sed 's|/home/|${AH}/|g')\"; done
        set -euo pipefail
        _create_deployer_config_from_template laravel demo git@github.com:a/b.git main 8.4
        echo REACHED" 2>&1)
    df="$AH/demo/.deployer/deploy.php"
    [[ "$(tail -n 1 <<< "$out")" == "REACHED" && -s "$df" ]] && ! grep -q '__CIPI_' "$df" && grep -q "set('branch', 'main');" "$df" && grep -q 'cipi:deploy-audit' "$df" \
        && pass "Laravel recipe with no extra artisan task: written, hook added, and the command goes on (the template ends on that placeholder)" \
        || fail "recipe under set -e: $(tail -n 2 <<< "$out" | tr '\n' ' ')"
fi

# ── 13. logrotate: each app's own logs, as the app user ─────
echo ""
echo "--- logrotate per app"
L13="$TMP/lr"; mkdir -p "$L13/d" "$L13/bin"
cat > "$L13/bin/install" <<'EOF'
#!/bin/bash
# install -m MODE -o OWNER -g GROUP SRC DST — here: a copy, the mode kept in a side file
src="${@: -2:1}"; dst="${@: -1}"; cp "$src" "$dst" && echo "$*" >> "${dst%/*}/.install-calls"
EOF
cat > "$L13/bin/id" <<'EOF'
#!/bin/bash
u="${@: -1}"; case "$u" in shop|blog|logs) ;; *) exit 1 ;; esac
case "$1" in -gn) echo "$u" ;; -u) echo 2001 ;; *) echo "uid=2001($u)" ;; esac
EOF
chmod +x "$L13/bin/"*
# common.sh whole: app_logrotate_rule holds a here-document with a "}" in the
# first column, which fn() would take for the end of the function.
lr() { PATH="$L13/bin:$PATH" CIPI_LOGROTATE_D="$L13/d" CIPI_CONFIG="$L13/etc" CIPI_LOG="$L13/log" CIPI_LIB="$LIB" bash -c "
    RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
    source '${LIB}/common.sh' 2>/dev/null
    set -euo pipefail
    _app_as() { echo \"as \$1\" >> '$L13/calls'; }
    $1" 2>&1; }
shared_old() { printf '%s\n' '/home/*/shared/storage/logs/*[!0-9].log' '/home/*/logs/php-fpm-*.log' '/var/log/cipi-apps/*/worker-*.log' '/var/log/cipi/*.log {' '    daily' '    copytruncate' '}' > "$L13/d/cipi-app-logs"; }
shared_old
lr 'app_logrotate_rule shop'
[[ ! -e "$L13/d/cipi-home-shop" ]] && pass "no per-app rule while the shared rule still names /home/* (a log named twice makes logrotate drop a file)" || fail "per-app rule written next to the /home/* lines"
out=$(lr 'app_logrotate_all shop blog; echo rc=$?')
grep -q 'rc=0' <<< "$out" && ! grep -q '/home/' "$L13/d/cipi-app-logs" && [[ "$(grep -c '' "$L13/d/cipi-app-logs")" == "5" ]] && grep -qx '/var/log/cipi-apps/\*/worker-\*.log' "$L13/d/cipi-app-logs" \
    && pass "the two /home/* lines leave the shared rule, the rest of it stays" || fail "shared rule after the strip: $(cat "$L13/d/cipi-app-logs") / ${out}"
r="$L13/d/cipi-home-shop"
[[ -f "$r" && -f "$L13/d/cipi-home-blog" ]] && grep -qx '    su shop shop' "$r" && grep -qx '/home/shop/shared/storage/logs/\*\[!0-9\].log' "$r" && grep -qx '/home/shop/logs/php-fpm-\*.log {' "$r" \
    && pass "each app has its rule: its two paths, rotated with su <app> <group>" || fail "per-app rule: $(cat "$r" 2>&1)"
for o in daily missingok 'rotate 365' compress delaycompress notifempty copytruncate; do grep -qx "    $o" "$r" || fail "per-app rule lost the option: $o"; done
! grep -qE 'postrotate|prerotate|firstaction|lastaction|sharedscripts|create ' "$r" && pass "no script in the rule (logrotate runs those as root even with su), no create" || fail "script or create in the per-app rule"
grep -q -- '-m 644 -o root -g root' "$L13/d/.install-calls" && pass "the rule file is root:root 0644 (anything else and logrotate ignores it)" || fail "rule file not installed root:root 0644"
before=$(ls -l --time-style=full-iso "$r"); sleep 1; lr 'app_logrotate_rule shop'; [[ "$(ls -l --time-style=full-iso "$r")" == "$before" ]] && pass "a second run rewrites nothing" || fail "rule rewritten on a second run"
grep -q 'as shop' "$L13/calls" && pass "the logs' group is put right by the app user itself" || fail "group not normalised as the app user"
: > "$L13/d/cipi-home-ghost"; lr 'app_logrotate_sweep'
[[ ! -e "$L13/d/cipi-home-ghost" && -e "$r" ]] && pass "a rule left by a user that no longer exists is swept (its su line is an error at every run)" || fail "sweep wrong: $(ls "$L13/d")"
lr 'app_logrotate_rule logs'; [[ -f "$L13/d/cipi-home-logs" && -f "$L13/d/cipi-app-logs" ]] && ! grep -q 'su logs' "$L13/d/cipi-app-logs" \
    && pass "an app named 'logs' does not collide with the shared rule (cipi-home-<app>, not cipi-app-<app>)" || fail "app 'logs' collides with cipi-app-logs"
lr 'app_logrotate_remove shop'; [[ ! -e "$r" ]] && pass "the rule goes with the app" || fail "rule left after remove"
printf '%s\n' '/home/*/shared/storage/logs/*[!0-9].log /home/*/logs/php-fpm-*.log {' '    weekly' '}' > "$L13/d/cipi-app-logs"; rm -f "$L13/d"/cipi-home-*
out=$(lr 'app_logrotate_all shop || echo rc=1')
grep -q 'rc=1' <<< "$out" && grep -q 'not the rule Cipi wrote' <<< "$out" && grep -q '/home/\*' "$L13/d/cipi-app-logs" && [[ -z "$(ls "$L13/d" | grep cipi-home || true)" ]] \
    && pass "a shared rule someone rearranged is left as it is, said, and no per-app rule is written" || fail "rearranged shared rule: ${out} / $(ls "$L13/d")"
! grep -q '^/home/\*/' "${ROOT}/setup.sh" && pass "setup.sh: the shared rule of a new server names no home" || fail "setup.sh still rotates /home/*"
grep -q 'app_logrotate_rule "$app" || true' "${LIB}/common.sh" && grep -q 'app_logrotate_remove "$app"' "${LIB}/app.sh" && grep -q 'app_logrotate_all \$lr_apps' "${LIB}/migrations/5.8.6.sh" \
    && pass "the rule is written with the app's permissions (create, deploy, import), removed with the app, and for every app by the migration" || fail "logrotate hooks missing"
grep -q 'find "\$d" -maxdepth 1 -type f -name "\*.log\*" ! -group "\$g" -exec chgrp "\$g" {} +' "${LIB}/common.sh" \
    && pass "ensure_app_logs_permissions: logs in a group the app user is not in (www-data, before 5.8.6) go to its own — logrotate cannot give a copy a group its user is not in" || fail "group normalisation missing"

# ── 14. pending, autoupdate, reboot ─────────────────────────
echo ""
echo "--- pending / autoupdate / reboot"
P14="$TMP/pend"; mkdir -p "$P14/bin" "$P14/etc" "$P14/boot"
pe() { PATH="$P14/bin:$PATH" CIPI_CONFIG="$P14/etc" CIPI_LIB="$LIB" REBOOT_FLAG="$P14/reboot-required" REBOOT_CRON="$P14/cron-reboot" PENDING_CRON="$P14/cron-pending" PENDING_CACHE="$P14/pending.cache" \
       PENDING_STATE="$P14/pending.state" AUTOUPDATE_CRON="$P14/cron-autoupdate" AUTOUPDATE_STATE="$P14/autoupdate.state" AUTOUPDATE_LOCK="$P14/lock" bash -c "
    set -euo pipefail
    RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
    info(){ echo \"INFO \$*\"; }; warn(){ echo \"WARN \$*\"; }; success(){ echo \"OK \$*\"; }; error(){ echo \"ERR \$*\" >&2; }; step(){ :; }
    log_action(){ echo \"log \$*\" >> '$P14/calls'; }; cipi_notify(){ echo \"notify \$3 | \$1\" >> '$P14/calls'; }
    vault_read(){ [[ -f \"\${CIPI_CONFIG}/\$1\" ]] && cat \"\${CIPI_CONFIG}/\$1\" || echo '{}'; }
    vault_write(){ cat > \"\${CIPI_CONFIG}/\$1\"; }
    $(fn common.sh parse_args); $(fn common.sh version_at_least)
    $(sed -n '/^composer_security_floor()/p;/^node_security_floor() {/,/^}/p;/^php_security_floor() {/,/^}/p' "${LIB}/common.sh")
    source '${LIB}/autoupdate.sh'; source '${LIB}/pending.sh'
    $1" 2>&1; }
is14() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1 (got: [$2] want: [$3])"; }
is14 "autoupdate: on for every component nobody decided about" "$(pe 'for c in $AUTOUPDATE_COMPONENTS; do autoupdate_enabled $c && printf 1 || printf 0; done')" "111111"
pe '_autoupdate_set mariadb false' >/dev/null
is14 "…off for one leaves the others on" "$(pe 'for c in nginx mariadb pgsql; do autoupdate_enabled $c && printf 1 || printf 0; done')" "101"
is14 "component names and aliases" "$(pe 'for n in nginx mysql postgres redis nodejs composer; do _autoupdate_normalize $n; done | paste -sd" " -; _autoupdate_normalize all || echo refused')" "nginx mariadb pgsql valkey node composer
refused"
is14 "the databases come last in a run" "$(pe 'echo $AUTOUPDATE_COMPONENTS')" "composer node nginx valkey pgsql mariadb"
pe 'mkdir -p /nonexistent 2>/dev/null; [[ -d /etc/cron.d ]] || exit 0; autoupdate_cron_write' >/dev/null
if [[ -f "$P14/cron-autoupdate" ]]; then
    grep -qx '20 4 \* \* \* root /usr/local/bin/cipi-cron-notify autoupdate /usr/local/bin/cipi autoupdate run >> /var/log/cipi/autoupdate.log 2>&1' "$P14/cron-autoupdate" && grep -q '^PATH=.*/usr/sbin' "$P14/cron-autoupdate" \
        && pass "the nightly job: 04:20, as root, through cipi-cron-notify, with sbin on its PATH (nginx -t)" || fail "autoupdate cron: $(cat "$P14/cron-autoupdate")"
fi
diff <(sed -n '/cat > \/etc\/cron.d\/cipi-autoupdate/,/^EOF/p' "${ROOT}/setup.sh" | sed '1d;$d') <(sed -n '/cat > "\$AUTOUPDATE_CRON"/,/^EOF/p' "${LIB}/autoupdate.sh" | sed '1d;$d') >/dev/null \
    && diff <(sed -n '/cat > \/etc\/cron.d\/cipi-pending/,/^EOF/p' "${ROOT}/setup.sh" | sed '1d;$d') <(sed -n '/cat > "\$PENDING_CRON"/,/^EOF/p' "${LIB}/pending.sh" | sed '1d;$d') >/dev/null \
    && pass "setup.sh writes the same two cron files the libs write" || fail "cron files of setup.sh and the libs differ"
grep -q '( set -e; _autoupdate_one "\$c" ) 8>&-' "${LIB}/autoupdate.sh" && grep -q '_autoupdate_db_busy' "${LIB}/autoupdate.sh" \
    && pass "each component runs in its own subshell, under errexit like the manual command, without the run's lock; a database waits while a dump or a deploy runs" || fail "autoupdate run structure"
grep -q '"valkey";' "${ROOT}/setup.sh" && grep -q '"nginx";' "${ROOT}/setup.sh" && pass "the four stay out of unattended-upgrades (it would restart them at any hour): Cipi patches them itself" || fail "unattended-upgrades blacklist changed"
grep -q 'readonly COMPOSER_MIN="2.10.3"' "${ROOT}/setup.sh" && is14 "Composer floor" "$(pe composer_security_floor)" "2.10.3"
is14 "Node floors" "$(pe 'for m in 20 22 24 26; do echo "$m:$(node_security_floor $m)"; done | paste -sd" " -')" "20: 22:22.23.4 24:24.22.1 26:26.12.1"
cat > "$P14/bin/apt-cache" <<'EOF'
#!/bin/bash
cat <<'OUT'
nginx:
  Installed: 1.29.3-1~noble
  Candidate: 1.29.5-1~noble
  Version table:
nginx-common:
  Installed: (none)
  Candidate: 1.29.5-1~noble
mariadb-server:
  Installed: 1:11.4.5
  Candidate: 1:11.4.5
OUT
EOF
chmod +x "$P14/bin/apt-cache"
is14 "packages waiting: installed ≠ candidate, not-installed ones ignored" "$(pe '_pending_apt_waiting nginx nginx-common mariadb-server')" "nginx 1.29.3-1~noble→1.29.5-1~noble"
cat > "$P14/bin/uname" <<'EOF'
#!/bin/bash
echo "6.8.0-110-generic"
EOF
chmod +x "$P14/bin/uname"
is14 "reboot: nothing to say without the flag (and without a newer kernel in /boot)" "$(pe 'reboot_needed || echo no')" "no"
: > "$P14/reboot-required"
out=$(pe 'reboot_needed'); [[ "$out" == "$(date -r "$P14/reboot-required" '+%Y-%m-%d')|6.8.0-110-generic|"* ]] && pass "reboot: Ubuntu's flag, with its date and the running kernel" || fail "reboot_needed: ${out}"
out=$(pe 'PENDING_ITEMS=(); _pending_reboot; printf "%s\n" "${PENDING_ITEMS[@]}"')
grep -q '^critical'$'\t''reboot'$'\t''Reboot required since' <<< "$out" && grep -q 'cipi reboot now' <<< "$out" && pass "pending: a waiting reboot is a critical item with what to run" || fail "pending reboot item: ${out}"
out=$(pe '_reboot_auto on --at=25:00' || true); grep -q 'ERR --at=HH:MM' <<< "$out" && [[ ! -e "$P14/cron-reboot" ]] && pass "reboot auto: a time that is not one is refused" || fail "bad --at accepted: ${out}"
if [[ -d /etc/cron.d ]]; then
    pe '_reboot_auto on --at=04:05' >/dev/null
    grep -qx '5 4 \* \* \* root /usr/local/bin/cipi reboot --if-required >> /var/log/cipi/reboot.log 2>&1' "$P14/cron-reboot" && pass "reboot auto on: one cron file, the given time, only --if-required" || fail "auto reboot cron: $(cat "$P14/cron-reboot" 2>&1)"
    pe '_reboot_auto off' >/dev/null; [[ ! -e "$P14/cron-reboot" ]] && pass "reboot auto off: the file goes" || fail "auto reboot cron left"
fi
grep -q 'Unattended-Upgrade::Automatic-Reboot "false";' "${ROOT}/setup.sh" && ! grep -q 'reboot_cron\|cipi-auto-reboot' "${ROOT}/setup.sh" && pass "automatic reboot stays opt-in: a new server does not restart itself" || fail "auto reboot enabled by setup.sh"
grep -q 'pgrep -x .apt-get|apt|dpkg|unattended-upgr.' "${LIB}/pending.sh" && grep -q "dep (deploy|rollback) " "${LIB}/pending.sh" && grep -q 'shutdown -r +2' "${LIB}/pending.sh" \
    && pass "the automatic reboot waits for package installations, dumps, deploys and other cipi commands, and warns two minutes ahead" || fail "automatic reboot guards"
# mail: once per list, again after 7 days
pe 'pending_collect(){ PENDING_ITEMS=("warning"$'"'"'\t'"'"'"x"$'"'"'\t'"'"'"Something waits"$'"'"'\t'"'"'"do it"); }; : > "'"$P14"'/calls"; _pending_cron >/dev/null; _pending_cron >/dev/null; grep -c "notify pending_report" "'"$P14"'/calls"' > "$P14/n1" 2>&1
is14 "pending --cron: the same list is mailed once, not every day" "$(cat "$P14/n1")" "1"
pe 'pending_collect(){ PENDING_ITEMS=("warning"$'"'"'\t'"'"'"x"$'"'"'\t'"'"'"Something waits"$'"'"'\t'"'"'"do it"); }; printf "%s\n%s\n" "$(head -1 "'"$P14"'/pending.state")" "$(( $(date +%s) - 8*86400 ))" > "'"$P14"'/pending.state"; : > "'"$P14"'/calls"; _pending_cron >/dev/null; grep -c "notify pending_report" "'"$P14"'/calls"' > "$P14/n2" 2>&1
is14 "…and again after a week, while it lasts" "$(cat "$P14/n2")" "1"
pe 'pending_collect(){ PENDING_ITEMS=(); }; _pending_cron >/dev/null; [[ ! -e "'"$P14"'/pending.state" ]] && echo cleared' > "$P14/n3" 2>&1
is14 "…an empty list clears the memory: the same problem coming back is news" "$(cat "$P14/n3")" "cleared"
is14 "pending --json with nothing waiting" "$(pe 'PENDING_ITEMS=(); _pending_json | jq -c .')" '{"count":0,"items":[]}'
mkdir -p "$P14/reg"; : > "$P14/reg/redis.reg"
grep -q "pecl_extensions" "${LIB}/pending.sh" && grep -q 'dpkg-query -S /usr/lib/php/2\*/\*.so' "${LIB}/pending.sh" \
    && ! cat "${ROOT}/setup.sh" "${LIB}"/*.sh | grep -vE '^[[:space:]]*#' | grep -qE '\bpecl install\b|php-pear|phpize' \
    && pass "PECL: Cipi installs no extension with it, and names the ones a server has (PECL's registry, .so files no package owns)" || fail "PECL detection missing, or Cipi itself uses pecl"
for c in pending reboot autoupdate valkey; do grep -q "^        ${c}[|)]" "${ROOT}/cipi" || fail "cipi does not dispatch: ${c}"; done
grep -q 'pending_status_section' "${ROOT}/cipi" && pass "cipi status shows what is waiting, when something is" || fail "cipi status does not show pending work"
for t in node_upgrade composer_upgrade pending_report reboot valkey_isolate; do grep -q "^${t}|" "${LIB}/notifications.sh" || fail "notification trigger missing: ${t}"; done

# ── 15. Valkey per app ──────────────────────────────────────
echo ""
echo "--- Valkey per app"
vk() { VALKEY_CONF_DIR="$TMP/vkc" VALKEY_DATA_DIR="$TMP/vkd" CIPI_LIB="$LIB" bash -c "
    set -euo pipefail
    source '${LIB}/valkey.sh'
    _valkey_server_bin(){ echo /usr/bin/valkey-server; }
    $1" 2>&1; }
u=$(vk _valkey_unit_text)
grep -qx 'User=%i' <<< "$u" && grep -qx 'ExecStart=/usr/bin/valkey-server '"$TMP"'/vkc/%i.conf --daemonize no --supervised no' <<< "$u" && grep -qx 'ProtectHome=true' <<< "$u" \
    && grep -qx 'NoNewPrivileges=true' <<< "$u" && grep -qx 'Restart=always' <<< "$u" && grep -qx 'StartLimitIntervalSec=0' <<< "$u" \
    && pass "the unit: one instance per app, as the app's user, without a view of /home, restarted for ever" || fail "unit text: ${u}"
c=$(vk '_valkey_conf_text shop 6400 SecretPass0123456789 64mb allkeys-lru')
grep -qx 'bind 127.0.0.1' <<< "$c" && grep -qx 'port 6400' <<< "$c" && grep -qx 'requirepass SecretPass0123456789' <<< "$c" && grep -qx 'protected-mode yes' <<< "$c" \
    && grep -qx "dir $TMP/vkd/shop" <<< "$c" && grep -qx 'maxmemory 64mb' <<< "$c" && grep -qx 'maxmemory-policy allkeys-lru' <<< "$c" \
    && pass "the configuration: localhost only, its own port, password and data directory" || fail "conf text: ${c}"
is14 "maxmemory and policy are validated" "$(vk 'for v in 64mb 1gb 0mb "64mb; x" 64; do _valkey_valid_maxmemory "$v" && printf 1 || printf 0; done; for p in allkeys-lru noeviction bogus; do _valkey_valid_policy "$p" && printf 1 || printf 0; done')" "11000110"
printf '%s\n' 'REDIS_HOST=127.0.0.1' 'REDIS_PASSWORD="a b"' "REDIS_PORT='6400'" > "$TMP/vk.env"
is14 ".env values, with or without quotes" "$(vk 't=$(cat "'"$TMP"'/vk.env"); echo "$(_valkey_env_get "$t" REDIS_HOST)|$(_valkey_env_get "$t" REDIS_PASSWORD)|$(_valkey_env_get "$t" REDIS_PORT)|$(_valkey_env_get "$t" REDIS_URL)"')" "127.0.0.1|a b|6400|"
is14 "a prefix is matched literally" "$(vk "_valkey_glob_escape 'a[b]*?_'")" 'a\[b\]\*\?_'
grep -q 'REDISCLI_AUTH="\$pass"' "${LIB}/valkey.sh" && ! grep -qE 'valkey-cli[^|]* -a |redis-cli[^|]* -a |--pass ' "${LIB}/valkey.sh" \
    && grep -q 'COPY REPLACE AUTH " . hx(\$pw)' "${LIB}/valkey.sh" \
    && pass "no password on a command line: the environment for the client, standard input (hex-quoted) for the copy" || fail "a Valkey password may reach a command line"
grep -q 'REDIS_HOST|REDIS_PORT|REDIS_PASSWORD|REDIS_USERNAME|REDIS_URL) continue' "${LIB}/app.sh" && pass "cipi app clone: the clone does not inherit the source's Valkey" || fail "clone copies REDIS_* from the source"
grep -q 'CIPI_KEEP_REDIS_PASSWORD="\$local_redis_pass"' "${LIB}/sync.sh" && grep -q 'DB_PORT DB_CONNECTION REDIS_HOST REDIS_PORT REDIS_PASSWORD' "${LIB}/sync.sh" && grep -q 'valkey_sync_adopt "\$app"' "${LIB}/sync.sh" && grep -q 'valkey_sync_keep "\$app"' "${LIB}/sync.sh" \
    && pass "cipi sync: an existing app keeps this server's Valkey settings; an imported one gets an instance here" || fail "sync does not handle Valkey"
grep -q 'valkey_instance_create "\$app_user"' "${LIB}/app.sh" && grep -q 'ARG_valkey:-own' "${LIB}/app.sh" && grep -q 'valkey_instance_remove "\$app"' "${LIB}/app.sh" \
    && pass "a new Laravel app gets its instance (--valkey=shared for the old behaviour); it goes with the app" || fail "app create/delete do not manage the instance"
grep -q 'valkey_instances_restart_all' "${LIB}/stack-upgrade.sh" && grep -q 'cipi-valkey@' "${LIB}/service.sh" \
    && pass "a Valkey package upgrade restarts the apps' instances; cipi service and the monitor see them" || fail "upgrade or service list ignore the per-app instances"
grep -q '_valkey_artisan "\$app" down' "${LIB}/valkey.sh" && [[ "$(grep -n '_valkey_copy "\$VALKEY_SHARED_PORT"' "${LIB}/valkey.sh" | cut -d: -f1)" -lt "$(grep -n '_valkey_env_switch "\$app" "\$port" "\$pass"; then' "${LIB}/valkey.sh" | head -1 | cut -d: -f1)" ]] \
    && pass "isolate: maintenance mode, copy, then the .env — a refused copy leaves the app where it was" || fail "isolate order"

# ── 16. the panel's trees ───────────────────────────────────
echo ""
echo "--- the panel's trees: composer, artisan and .env as www-data"
E16="$TMP/panel.env"; printf 'APP_URL=http://old\nLOG_CHANNEL=daily\n' > "$E16"
out=$(bash -c "set -euo pipefail; $(fn common.sh _panel_env_set_do); _panel_env_set_do '$E16' APP_URL 'https://a|b&c\\d' LOG_STACK 'single,stderr' 'BAD KEY' x; cat '$E16'")
[[ "$out" == $'APP_URL=https://a|b&c\\d\nLOG_CHANNEL=daily\nLOG_STACK=single,stderr' ]] && pass ".env edit: replace, append, the value as data, odd key names skipped" || fail "_panel_env_set_do: ${out}"
ln -s "$E16" "$TMP/panel.link"; bash -c "$(fn common.sh _panel_env_set_do); _panel_env_set_do '$TMP/panel.link' APP_URL x" 2>/dev/null \
    && fail "a .env that is a symlink was edited" || pass "a .env that is a symlink is refused"
api_live=$(grep -vE '^[[:space:]]*#' "${LIB}/api.sh" | sed -n '/^_api_update_package() {/,/^}/p'); gui_live=$(grep -vE '^[[:space:]]*#' "${LIB}/gui.sh")
! grep -qE '\(cd "\$\{CIPI_API_ROOT\}" && composer ' <<< "$api_live" && grep -q 'panel_composer "${CIPI_API_ROOT}" require cipi/api' <<< "$api_live" \
    && ! grep -qE '&& composer (config|require|reinstall|update)' <<< "$gui_live" \
    && pass "no composer run by root in the live trees: panel_composer everywhere" || fail "root still runs composer in a panel tree"
grep -q 'chown -h -R www-data:www-data "${CIPI_API_ROOT}"' "${LIB}/api.sh" && ! grep -qE '^[^#]*chown www-data:www-data "\$\{?(envf|CIPI_API_ROOT|CIPI_GUI_ROOT|root|dest)' "${LIB}/api.sh" "${LIB}/gui.sh" "${LIB}/common.sh" \
    && pass "no chown by name inside a panel tree: -h -R on the tree, the rest as www-data" || fail "a chown in a panel tree still follows links"
for f in _api_ensure_log_stack_env _api_ensure_session_driver_env _api_set_app_url; do fn api.sh "$f" | grep -q 'panel_env_set' || fail "api.sh ${f} does not use panel_env_set"; done
for f in _gui_ensure_log_stack_env _gui_ensure_session_driver_env _gui_set_app_url; do fn gui.sh "$f" | grep -q 'panel_env_set' || fail "gui.sh ${f} does not use panel_env_set"; done
fn common.sh _panel_tree_is_www | grep -q 'CIPI_API_ROOT:-/opt/cipi/api' && ! fn common.sh _panel_tree_is_www | grep -q 'stat ' \
    && pass "a panel tree is known by where it is, not by its owner of the moment (self-update chowns /opt/cipi to root before it updates the panel)" || fail "_panel_tree_is_www goes by owner"
fnc gui.sh _gui_reset_primary_admin | grep -q 'mktemp /run/cipi-gui-reset' && ! fnc gui.sh _gui_reset_primary_admin | grep -q 'storage/app' \
    && pass "gui reset-user: the new password travels in a file of root's making, outside the tree" || fail "reset payload still written in the tree"

# ── 17. sshd: the server's keys for app users ───────────────
echo ""
echo "--- sshd section"
diff <(sed -n '/^# >>> cipi ssh apps/,/^# <<< cipi ssh apps/p' "${ROOT}/setup.sh") <(SSH_APPS_GROUP=cipi-nossh bash -c "$(fn ssh.sh _ssh_apps_section); _ssh_apps_section") >/dev/null \
    && pass "setup.sh and lib/ssh.sh write the same section" || fail "the sshd section of setup.sh and ssh.sh differ"
sec=$(SSH_APPS_GROUP=cipi-nossh bash -c "$(fn ssh.sh _ssh_apps_section); _ssh_apps_section")
[[ "$(grep -c '^Match ' <<< "$sec")" == "3" ]] && [[ "$(grep -n 'AuthorizedKeysFile none' <<< "$sec" | cut -d: -f1)" -lt "$(grep -n '^Match Group cipi-nossh Address 127' <<< "$sec" | cut -d: -f1)" ]] \
    && [[ "$(grep -c 'AuthorizedKeysCommand /usr/local/bin/cipi-ssh-keys %u' <<< "$sec")" == "2" && "$(grep -c 'AuthorizedKeysCommandUser cipi' <<< "$sec")" == "2" ]] && ! grep -q 'DenyUsers' <<< "$sec" \
    && pass "disabled from outside: public key only, the app's own keys off, the server's keys on; enabled: password, own keys and the server's" || fail "section: ${sec}"
S17="$TMP/sshd"; printf '%s\n' 'Port 22' 'AllowGroups cipi-ssh cipi-apps' '' 'Match Group cipi-apps' '    PasswordAuthentication yes' '' '# cipi ssh apps — no SSH/SFTP from outside for members of cipi-nossh.' '# Logins from the server itself stay allowed: deploys run over ssh localhost.' 'Match Group cipi-nossh Address *,!127.0.0.1,!::1' '    DenyUsers *' > "$S17"
out=$(SSH_APPS_GROUP=cipi-nossh bash -c "$(fn ssh.sh _ssh_apps_strip); _ssh_apps_strip '$S17'")
[[ "$out" == $'Port 22\nAllowGroups cipi-ssh cipi-apps' ]] && pass "the two blocks older versions wrote are taken out whole, the rest stays" || fail "strip of the legacy blocks: ${out}"
printf '%s\n' 'Port 22' 'Match Group cipi-apps' '    PasswordAuthentication yes' '    X11Forwarding no' 'Match User backup' '    ForceCommand /bin/true' > "$S17"
out=$(SSH_APPS_GROUP=cipi-nossh bash -c "$(fn ssh.sh _ssh_apps_strip); _ssh_apps_strip '$S17'")
grep -q 'X11Forwarding no' <<< "$out" && grep -q 'Match User backup' <<< "$out" && grep -q 'ForceCommand /bin/true' <<< "$out" && pass "a block someone added to, and other people's blocks, are kept" || fail "strip removed a customised block: ${out}"
k="${LIB}/cipi-ssh-keys.sh"; [[ "$(head -1 "$k")" == '#!/bin/sh' ]] && grep -qx 'f=/home/cipi/.ssh/authorized_keys' "$k" && [[ "$(grep -vcE '^#|^$' "$k")" == "3" ]] \
    && pass "cipi-ssh-keys prints the cipi user's keys and does nothing else" || fail "cipi-ssh-keys is not the three lines it should be"
printf 'ssh-ed25519 AAAAkey admin\n' > "$TMP/ak"; out=$(sed "s|/home/cipi/.ssh/authorized_keys|$TMP/ak|" "$k" | sh -s someapp)
[[ "$out" == "ssh-ed25519 AAAAkey admin" ]] && [[ -z "$(sed "s|/home/cipi/.ssh/authorized_keys|$TMP/none|" "$k" | sh -s x)" ]] && pass "…read at every login: no copy of the keys per app to keep in step" || fail "cipi-ssh-keys output: ${out}"
grep -q 'cipi-ssh-keys.sh" /usr/local/bin/cipi-ssh-keys && chown root:root' "${LIB}/self-update.sh" && grep -q 'chmod 755 /usr/local/bin/cipi-ssh-keys' "${ROOT}/setup.sh" && grep -q '_ssh_apps_ensure_block' "${LIB}/migrations/5.8.6.sh" \
    && pass "the helper is installed root:root 0755 (sshd refuses anything else) by setup, self-update and the migration" || fail "cipi-ssh-keys install"

# ── 18. API tokens: full access; deploy lock; auth create ───
echo ""
echo "--- api token --full-access, deploy lock, auth create"
T18="$TMP/tok"; mkdir -p "$T18/api"; : > "$T18/api/artisan"; echo '{}' > "$T18/api.json"
tk() { bash -c "
    set -uo pipefail
    RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; NC=''; BOLD=''
    info(){ :; }; step(){ :; }; error(){ echo \"ERR \$*\"; }; ensure_cipi_api_permissions(){ :; }; read_input(){ echo 'PROMPT'; exit 9; }
    sudo(){ echo \"\$*\" > '$T18/call'; echo 'Token: 1|abc'; }
    _api_ability_lines(){ printf 'apps-view|Read apps\ndeploy-manage|Deploy\n'; }
    CIPI_API_CONFIG='$T18/api.json'; CIPI_API_ROOT='$T18/api'
    $(fn common.sh parse_args); $(fn api.sh api_token_create)
    api_token_create $1" 2>&1 < /dev/null; }
: > "$T18/call"; tk '--name=ci --full-access' >/dev/null; grep -q -- '--name=ci --abilities=\* --expires-at=$' "$T18/call" && pass "--full-access: the wildcard ability, no questions asked" || fail "full access call: $(cat "$T18/call")"
: > "$T18/call"; tk '--name=ci --abilities=apps-view,deploy-manage --expires=2027-01-31' >/dev/null; grep -q -- '--abilities=apps-view,deploy-manage --expires-at=2027-01-31' "$T18/call" && pass "--abilities and --expires without the checklist" || fail "abilities call: $(cat "$T18/call")"
: > "$T18/call"; out=$(tk '--name=ci --abilities=apps-view,nope'); grep -q 'ERR Unknown ability: nope' <<< "$out" && [[ ! -s "$T18/call" ]] && pass "an ability the API does not have is refused" || fail "unknown ability: ${out}"
: > "$T18/call"; out=$(tk "--name=ci --abilities='apps-view;id'"); grep -q 'ERR Invalid --abilities' <<< "$out" && [[ ! -s "$T18/call" ]] && pass "…and so is a list that is not one" || fail "bad abilities: ${out}"
fn api.sh _api_token_select_abilities | grep -q 'f | full | full-access)' && pass "the checklist offers full access too (f)" || fail "checklist has no full access"
for t in laravel laravel-octane; do grep -qx "after('deploy:failed', 'deploy:unlock');" "${LIB}/deployer/${t}.php" || fail "${t}.php does not release the lock on failure"; done
D18="$TMP/dep"; mkdir -p "$D18"; printf "<?php\nnamespace Deployer;\nrequire 'recipe/laravel.php';\nafter('deploy:symlink', 'workers:restart');\n" > "$D18/deploy.php"
du() { bash -c "set -euo pipefail
    app_get(){ echo \"\${CUSTOM:-false}\"; }; app_read(){ cat \"\$2\"; }; app_append(){ cat >> \"\$2\"; }
    $(fn common.sh deployer_unlock_ensure_hook | sed "s|/home/\${app}/.deployer/deploy.php|$D18/deploy.php|")
    deployer_unlock_ensure_hook demo"; }
du; du; [[ "$(grep -c "^after('deploy:failed', 'deploy:unlock');$" "$D18/deploy.php")" == "1" ]] && pass "an existing Laravel deploy.php gets the line, once" || fail "unlock hook: $(cat "$D18/deploy.php")"
printf "<?php\nnamespace Deployer;\n// classic\n" > "$D18/deploy.php"; du; ! grep -q 'deploy:unlock' "$D18/deploy.php" && pass "a custom app's recipe (no lock) is left alone" || fail "unlock hook added to a custom recipe"
grep -q 'if \[\[ -z "\$repository" && "\${ARG_repository+x}" != x && -t 0 \]\]; then' "${LIB}/app.sh" \
    && pass "app create --custom asks for the repository on a terminal only (from the panel the question was the error)" || fail "custom app create still prompts without a terminal"
ac=$(sed -n '/^auth_create() {/,/^auth_edit() {/p' "${LIB}/app.sh")
grep -q 'if \[\[ -t 0 && -t 1 && "${ARG_no_edit:-}" != "true" \]\]; then' <<< "$ac" && grep -q '^        auth_edit "\$app"$' <<< "$ac" \
    && pass "cipi auth create opens the editor on a terminal (not for the panel, not with --no-edit)" || fail "auth create does not open the editor"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
